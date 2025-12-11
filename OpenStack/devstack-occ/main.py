import os
from dotenv import load_dotenv
from fastapi import FastAPI, Request, Header
from typing import Optional
import sys
import openstack
import openstack.orchestration
import openstack.orchestration.v1
import json
import datetime
import logging

sys.path.append(os.path.join(os.path.dirname(__file__), ".."))

from src.stack0 import handle_scale_request

logging.getLogger().setLevel(logging.INFO)


load_dotenv(verbose=True, override=True)

app = FastAPI()
cloud = openstack.connect(cloud="envvars")
heat = openstack.orchestration.v1._proxy.Proxy(cloud)

lastest_request = None


@app.get("/")
def read_root():
    lastest_request = None
    with open("latest_request.json", "r") as f:
        lastest_request = json.load(f)
    return {
        "Hello": "World!",
        "lastest_request": lastest_request,
        "cloud": {
            "auth": cloud.auth,
            # "endpoints": cloud.list_endpoints(),
        },
        "lastest_request": lastest_request,
    }


@app.post("/{stack_id}/{aspect}/{method}")
async def scale(
    request: Request,
    stack_id: str,
    aspect: str,
    method: str,
    authorization: Optional[str] = Header(None),
):
    # Extract route
    route = request.url.path

    # Extract headers
    headers = dict(request.headers)

    # Extract body (try JSON, fall back to raw)
    try:
        body = await request.json()
    except Exception:
        body = await request.body()
        body = body.decode("utf-8")

    try:
        stack = cloud.get_stack(stack_id)

        stack_dict = stack.to_dict()

        response_data = {
            "timestamp": datetime.datetime.utcnow().isoformat(),
            "stack_id": stack_id,
            "alarm_body": body,
            "alarm_info": {
                "route": route,
                "auth_token": authorization or "No Authorization header",
                "headers": headers,
            },
            "stack": stack_dict,
        }

        with open("latest_request.json", "w") as f:
            json.dump(response_data, f, indent=4)

        handle_scale_request(stack, aspect, method, body, cloud)
    except Exception:
        pass

    print("Received SCALE request: ", aspect, " request: ", method)
    return None


@app.post("/{full_path:path}")
async def catch_all(request: Request):
    print("Received POST request:", request.url.path)
    pass


if __name__ == "__main__":
    # ray_app = FastAPIWrapper.bind()
    os.system(
        "uvicorn src.main:app --reload --host 0.0.0.0 --port 8080 --env-file .env"
    )
    # os.system("serve run main:ray_app")
