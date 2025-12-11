import openstack.connection
from openstack.orchestration.v1.stack import Stack
import openstack
import json
from datetime import datetime, timezone, timedelta
import logging
from dotenv import load_dotenv
import subprocess
import os
import sys

autoscaling = False
# temp, to make stack update only once
stack_scale_up_delay = 1000  # seconds
stack_scale_down_delay = 600  # seconds
stack_create_delay = 1500  # seconds


def get_current_scale_level(stack: Stack, aspect: str) -> int:
    stack_params = stack.parameters
    return int(stack_params.get(f"{aspect}-scale-level", "0"))


def get_scale_levels(stack: Stack, aspect: str) -> list:
    stack_params = stack.parameters
    scaling_params = json.loads(
        stack_params.get(f"{aspect}-scaling", '{"scale-levels":[]}')
    )
    # logging.info(scaling_params)
    # logging.info(scaling_params.get("scale-levels", []))
    return scaling_params.get("scale-levels", [])


def update_scale_level(stack: Stack, aspect: str, level: int, wait: bool = False):
    if autoscaling == False:
        print("autoscaling is temporary disabled")
        return

    my_env = os.environ.copy()
    my_env["PATH"] = f"/usr/sbin:/sbin:{my_env['PATH']}"
    # openstack stack update -e env1.yaml --existing stack0

    if wait == False:
        subprocess.run(
            [
                "openstack",
                "stack",
                "update",
                "--parameter",
                f"{aspect}-scale-level={level}",
                "--existing",
                stack.name,
            ],
            env=my_env,
            stderr=sys.stderr,
            stdout=sys.stdout,
        )
    else:
        subprocess.run(
            [
                "openstack",
                "stack",
                "update",
                "--parameter",
                f"{aspect}-scale-level={level}",
                "--wait",
                "--existing",
                stack.name,
            ],
            env=my_env,
            stderr=sys.stderr,
            stdout=sys.stdout,
        )


def handle_scale_request(
    stack: Stack,
    aspect: str,
    method: str,
    alarm_body: dict,
    cloud: openstack.connection.Connection,
):
    if stack.status != "UPDATE_COMPLETE" and stack.status != "CREATE_COMPLETE" and stack.status != "CHECK_COMPLETE":
        logging.warning("Stack is not in a valid state for scaling")
        return

    # Determine the scale level
    current_scale_level = get_current_scale_level(stack, aspect)
    scale_levels = get_scale_levels(stack, aspect)
    logging.info(current_scale_level)
    logging.info(method)
    logging.info(len(scale_levels) - 1)
    new_scale_level = current_scale_level

    try:
        if method == "SCALE_IN":
            new_scale_level = max(current_scale_level - 1, 0)
        elif method == "SCALE_OUT":
            new_scale_level = min(current_scale_level + 1, len(scale_levels) - 1)
        else:
            logging.warning(f"Unknown method: {method}")
    except Exception as e:
        logging.warning(e)
        return

    logging.info(new_scale_level)

    if new_scale_level == current_scale_level:
        logging.info("No scaling needed")
        return
    stack_update_delay = (
        stack_scale_up_delay
        if new_scale_level > current_scale_level
        else stack_scale_down_delay
    )

    # Chcck time for scaling
    logging.info(f"Scaling to {new_scale_level}")
    last_update_time = stack.updated_at
    if last_update_time is None:
        last_update_time = stack.created_at
        last_update_time = datetime.strptime(
            last_update_time, "%Y-%m-%dT%H:%M:%SZ"
        ).replace(tzinfo=timezone.utc)
        last_update_time = last_update_time + timedelta(
            seconds=stack_create_delay - stack_update_delay
        )
    else:
        last_update_time = datetime.strptime(
            last_update_time, "%Y-%m-%dT%H:%M:%SZ"
        ).replace(tzinfo=timezone.utc)

    current_time = datetime.utcnow().replace(tzinfo=timezone.utc)

    logging.info(f"current time:    {current_time.isoformat()}")
    logging.info(f"last stack time:  {last_update_time.isoformat()}")
    time_passed = current_time - last_update_time
    logging.debug("time passed (s): ", int(time_passed.total_seconds()))

    if time_passed.total_seconds() < stack_update_delay:
        logging.warning(
            f"Stack update delay not met: {time_passed.total_seconds()} < {stack_update_delay}"
        )
        return

    # Update the stack
    logging.info(
        f"Updating stack {stack.name} to scale level {new_scale_level} for aspect {aspect}"
    )
    # logging.info("Temporary disable stack update")
    update_scale_level(stack=stack, aspect=aspect, level=new_scale_level, wait=False)
    logging.info("Stack updated")


# if __name__ == "__main__":
#     load_dotenv(verbose=True, override=True)

#     cloud = openstack.connect()
#     stack = cloud.get_stack("stack0")

#     update_scale_level(stack=stack, level=1, wait=True)

#     print("Stack updated")
#     # print(cloud.get_stack("stack0"))
