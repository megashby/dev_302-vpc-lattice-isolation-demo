FROM public.ecr.aws/lambda/python:3.13

# COPY requirements.txt ${LAMBDA_TASK_ROOT}

# Install dependencies directly into the task root
# RUN pip install -r requirements.txt

# Copy all function code into the task root
COPY . ${LAMBDA_TASK_ROOT}

# Set the CMD to your handler (format: <file_name>.<function_name>)
CMD [ "index.lambda_handler" ]



