import azure.functions as func
import logging
import json
from datetime import datetime

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

@app.route(route="health")
def health_check(req: func.HttpRequest) -> func.HttpResponse:
    """Health check endpoint for Container Apps probes."""
    logging.info('Health check endpoint called')

    return func.HttpResponse(
        json.dumps({
            "status": "healthy",
            "timestamp": datetime.utcnow().isoformat()
        }),
        mimetype="application/json",
        status_code=200
    )

@app.route(route="hello")
def hello_world(req: func.HttpRequest) -> func.HttpResponse:
    """Simple HTTP-triggered function."""
    logging.info('Hello World function triggered')

    name = req.params.get('name')
    if not name:
        try:
            req_body = req.get_json()
            name = req_body.get('name')
        except ValueError:
            pass

    if name:
        message = f"Hello, {name}! This function scaled from zero to serve your request."
    else:
        message = "Hello! This function scaled from zero to serve your request. Pass a 'name' parameter to personalize the greeting."

    response = {
        "message": message,
        "timestamp": datetime.utcnow().isoformat(),
        "scaled_from_zero": True
    }

    return func.HttpResponse(
        json.dumps(response),
        mimetype="application/json",
        status_code=200
    )
