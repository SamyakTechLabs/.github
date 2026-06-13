"""S3 file sanitizer Lambda.

Triggered by S3 ``ObjectCreated`` events. Sanitizes PDFs, raster images, and
SVGs in place, then writes the cleaned object back with a ``sanitized: true``
metadata flag. If sanitization fails for any reason the object is deleted, so
unsafe content is never left in the bucket.

The function is bucket- and region-agnostic: it reads the bucket and key from
the triggering event, so the same deployment can serve any number of buckets.

Tunable via environment variables (all optional):
  MAX_FILE_SIZE_MB       Largest object processed, in MB.        Default: 50
  MAX_IMAGE_DIMENSION    Max width/height (px); larger images
                         are downscaled, preserving aspect ratio. Default: 4096
"""

import json
import logging
import os
import boto3
from io import BytesIO
from urllib.parse import unquote_plus

from PIL import Image
import PyPDF2

import xml.etree.ElementTree as ET
from defusedxml import ElementTree as DefusedET

# ---------------- CONFIG ----------------

s3 = boto3.client('s3')

logger = logging.getLogger()
logger.setLevel(logging.INFO)

MAX_FILE_SIZE = int(os.environ.get('MAX_FILE_SIZE_MB', '50')) * 1024 * 1024
_MAX_DIM = int(os.environ.get('MAX_IMAGE_DIMENSION', '4096'))
MAX_IMAGE_SIZE = (_MAX_DIM, _MAX_DIM)

SVG_NS = "http://www.w3.org/2000/svg"

SAFE_SVG_TAGS = {
    'svg', 'g', 'path', 'rect', 'circle', 'ellipse',
    'line', 'polyline', 'polygon',
    'defs', 'linearGradient', 'radialGradient', 'stop',
    'clipPath', 'mask',
    'title', 'desc',
}

SAFE_SVG_ATTRS = {
    'd', 'x', 'y', 'cx', 'cy', 'r', 'rx', 'ry',
    'width', 'height', 'viewBox',
    'fill', 'stroke', 'stroke-width',
    'stroke-linecap', 'stroke-linejoin',
    'opacity',
    'offset', 'stop-color', 'stop-opacity',
    'id'
}


def lambda_handler(event, context):
    bucket = None
    key = None
    try:
        record = event['Records'][0]
        bucket = record['s3']['bucket']['name']
        key = unquote_plus(record['s3']['object']['key'])
        size = record['s3']['object']['size']

        logger.info(f"Processing {bucket}/{key}, size={size}")

        if size > MAX_FILE_SIZE:
            raise ValueError(f"File too large: {size} bytes (max {MAX_FILE_SIZE})")

        response = s3.get_object(Bucket=bucket, Key=key)
        content = response['Body'].read()
        metadata = response.get('Metadata', {})

        if metadata.get('sanitized') == 'true':
            logger.info("Already sanitized, skipping")
            return success("Already sanitized")

        key_lower = key.lower()

        if key_lower.endswith('.pdf'):
            sanitized = sanitize_pdf(content)
            content_type = 'application/pdf'

        elif key_lower.endswith('.svg'):
            sanitized = sanitize_svg(content)
            content_type = 'image/svg+xml'

        elif key_lower.endswith(('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.tiff')):
            sanitized = sanitize_image(content)
            content_type = response.get('ContentType', 'application/octet-stream')

        else:
            logger.info(f"Unsupported file type, skipping sanitization: {key}")
            return success("Skipped — unsupported file type")

        s3.put_object(
            Bucket=bucket,
            Key=key,
            Body=sanitized,
            ContentType=content_type,
            ServerSideEncryption='AES256',
            Metadata={
                'sanitized': 'true',
                'request-id': context.aws_request_id,
            }
        )

        logger.info(f"Sanitization successful: {bucket}/{key}")
        return success("File sanitized")

    except Exception as e:
        logger.error(f"Processing failed for {bucket}/{key}: {e}")

        # Delete the file — do not leave potentially unsafe content in the bucket
        if bucket and key:
            try:
                s3.delete_object(Bucket=bucket, Key=key)
                logger.info(f"Deleted unsafe file: {bucket}/{key}")
            except Exception as del_err:
                logger.error(f"Failed to delete file {bucket}/{key}: {del_err}")

        return failure(str(e))


def success(msg):
    return {
        'statusCode': 200,
        'body': json.dumps({'message': msg})
    }


def failure(msg):
    return {
        'statusCode': 400,
        'body': json.dumps({'error': msg})
    }


# ---------------- PDF ----------------

def sanitize_pdf(pdf_bytes):
    reader = PyPDF2.PdfReader(BytesIO(pdf_bytes))
    writer = PyPDF2.PdfWriter()

    for page in reader.pages:
        for key in ['/AA', '/OpenAction']:
            if key in page:
                del page[key]
        writer.add_page(page)

    root = reader.trailer.get('/Root')
    if root:
        root_obj = root.get_object() if hasattr(root, 'get_object') else root
        for key in ['/AA', '/OpenAction', '/Names']:
            if key in root_obj:
                del root_obj[key]

    out = BytesIO()
    writer.write(out)
    out.seek(0)
    return out.read()


# ---------------- IMAGES ----------------

def sanitize_image(image_bytes):
    img = Image.open(BytesIO(image_bytes))
    fmt = img.format

    # Re-render pixel data — strips EXIF, metadata, and any embedded payloads
    clean = Image.new(img.mode, img.size)
    clean.putdata(list(img.getdata()))

    if clean.size[0] > MAX_IMAGE_SIZE[0] or clean.size[1] > MAX_IMAGE_SIZE[1]:
        clean.thumbnail(MAX_IMAGE_SIZE, Image.Resampling.LANCZOS)

    # JPEG does not support alpha channels
    if fmt == 'JPEG' and clean.mode in ('RGBA', 'LA', 'P'):
        clean = clean.convert('RGB')

    out = BytesIO()
    save_args = {}
    if fmt == 'JPEG':
        save_args = {'quality': 95, 'optimize': True}

    clean.save(out, format=fmt, **save_args)
    out.seek(0)
    return out.read()


# ---------------- SVG ----------------

def sanitize_svg(svg_bytes):
    root = DefusedET.fromstring(svg_bytes)

    def clean(elem):
        tag = elem.tag.split('}')[-1] if '}' in elem.tag else elem.tag

        if tag not in SAFE_SVG_TAGS:
            return None

        attrs = {}
        for k, v in elem.attrib.items():
            attr = k.split('}')[-1] if '}' in k else k
            if attr not in SAFE_SVG_ATTRS:
                continue

            # Only block script and data URI schemes — http/https in plain
            # attribute values (not href) are harmless since href is not in
            # SAFE_SVG_ATTRS and external references are already blocked.
            v_lower = v.lower().strip()
            if v_lower.startswith(('javascript:', 'data:')):
                continue

            attrs[attr] = v

        new_elem = ET.Element(f"{{{SVG_NS}}}{tag}", attrs)

        # Preserve text content for title/desc elements
        if elem.text and elem.text.strip():
            new_elem.text = elem.text

        for child in elem:
            cleaned_child = clean(child)
            if cleaned_child is not None:
                new_elem.append(cleaned_child)

        return new_elem

    cleaned = clean(root)
    if cleaned is None:
        raise ValueError("SVG root element was rejected during sanitization")

    return ET.tostring(cleaned, encoding='utf-8', xml_declaration=True)
