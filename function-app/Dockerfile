# Use Azure Functions Python base image
# Build for AMD64 (Azure Container Apps platform)
FROM --platform=linux/amd64 mcr.microsoft.com/azure-functions/python:4-python3.11

# Set environment variables
ENV AzureWebJobsScriptRoot=/home/site/wwwroot \
    AzureFunctionsJobHost__Logging__Console__IsEnabled=true \
    FUNCTIONS_WORKER_RUNTIME=python

# Copy function app files
COPY requirements.txt /home/site/wwwroot/
COPY function_app.py /home/site/wwwroot/
COPY host.json /home/site/wwwroot/

# Install Python dependencies
RUN cd /home/site/wwwroot && \
    pip install --no-cache-dir -r requirements.txt
