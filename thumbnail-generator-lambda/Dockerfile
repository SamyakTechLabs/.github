# Dockerfile
FROM public.ecr.aws/lambda/python:3.9

# Copy the function code and requirements file
COPY app.py ${LAMBDA_TASK_ROOT}
COPY requirements.txt ${LAMBDA_TASK_ROOT}

# Install the dependencies
RUN pip install -r requirements.txt

# Set the CMD to your handler (app.lambda_handler)
CMD ["app.lambda_handler"]
