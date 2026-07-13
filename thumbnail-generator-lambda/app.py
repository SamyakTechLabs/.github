import io
import mimetypes
import urllib.parse

import boto3
from PIL import Image

THUMBNAIL_SIZES = {
    "128": (128, 128),
    "512": (512, 512),
    "1024": (1024, 1024),
}
THUMBNAIL_FOLDER_NAMES = {f"thumbnails_{size_name}" for size_name in THUMBNAIL_SIZES}
SUPPORTED_IMAGE_EXTENSIONS = (".jpg", ".jpeg", ".png", ".gif")


def split_namespace_key(key):
    parts = key.split("/", 1)
    if len(parts) != 2 or not parts[0] or not parts[1]:
        return None, None
    return parts[0], parts[1]



def is_generated_thumbnail_key(key):
    if key.startswith("thumbnails/") or key.startswith("thumbnails_"):
        return True

    _, relative_key = split_namespace_key(key)
    if not relative_key:
        return False

    first_relative_segment = relative_key.split("/", 1)[0]
    return first_relative_segment == "thumbnails" or first_relative_segment in THUMBNAIL_FOLDER_NAMES



def is_supported_image_key(key):
    mime_type, _ = mimetypes.guess_type(key)

    if not mime_type or not mime_type.startswith("image/"):
        print(f"Skipping non-image file: {key} with MIME type: {mime_type}")
        return False

    if not key.lower().endswith(SUPPORTED_IMAGE_EXTENSIONS):
        print(f"Skipping file with unsupported extension: {key}")
        return False

    return True



def build_thumbnail_key(key, size_name):
    namespace, relative_key = split_namespace_key(key)
    if not namespace or not relative_key:
        raise ValueError(f"Source key must include a namespace: {key}")

    return f"{namespace}/thumbnails_{size_name}/{relative_key}"



def resolve_save_format(image, key):
    if image.format in {"JPEG", "PNG"}:
        return image.format
    if key.lower().endswith(".png"):
        return "PNG"
    return "JPEG"



def prepare_image_for_format(image, save_format):
    if save_format == "JPEG" and image.mode != "RGB":
        return image.convert("RGB")

    if save_format == "PNG" and image.mode not in {"RGB", "RGBA"}:
        return image.convert("RGBA")

    return image



def lambda_handler(event, context):
    print("Event: ", event)

    records = event.get("Records")
    if not records:
        print("No records found in the event.")
        return

    bucket = records[0]["s3"]["bucket"]["name"]
    key = urllib.parse.unquote_plus(records[0]["s3"]["object"]["key"])
    print(f"Decoded key: {key}")

    namespace, relative_key = split_namespace_key(key)
    if not namespace or not relative_key:
        print(f"Skipping processing for invalid namespaced key: {key}")
        return

    if is_generated_thumbnail_key(key):
        print(f"Skipping thumbnail creation for: {key}")
        return

    if not is_supported_image_key(key):
        return

    s3_client = boto3.client("s3")

    try:
        image_object = s3_client.get_object(Bucket=bucket, Key=key)
        image_content = image_object["Body"].read()
        image = Image.open(io.BytesIO(image_content))

        for size_name, size in THUMBNAIL_SIZES.items():
            image_copy = image.copy()
            image_copy.thumbnail(size)

            save_format = resolve_save_format(image, key)
            image_copy = prepare_image_for_format(image_copy, save_format)

            thumbnail_buffer = io.BytesIO()
            image_copy.save(thumbnail_buffer, format=save_format, optimize=True)

            thumbnail_key = build_thumbnail_key(key, size_name)
            content_type = "image/jpeg" if save_format == "JPEG" else "image/png"

            s3_client.put_object(
                Bucket=bucket,
                Key=thumbnail_key,
                Body=thumbnail_buffer.getvalue(),
                ACL="public-read",
                ContentType=content_type,
            )
            print(f"Thumbnail created at {thumbnail_key}")

    except Exception as exc:
        print(f"Error processing image: {exc}")
        raise

    return {
        "statusCode": 200,
        "body": "Thumbnails created successfully.",
    }
