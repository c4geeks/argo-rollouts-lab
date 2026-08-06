#!/usr/bin/env python3
"""Screenshot helper for the lab.

Chromium's --host-resolver-rules maps demo.example.com straight at the ALB's IP,
so the browser sends the right Host header, the traffic really does go through
the load balancer, and the address bar shows a clean hostname instead of the
generated k8s-*.elb.amazonaws.com name.

  shoot.py grid   OUT.png --alb-ip 1.2.3.4 [--host demo.example.com] [--settle 25]
  shoot.py page   OUT.png --url http://127.0.0.1:13000/d/xyz [--settle 8] [--full]
"""
import argparse
import sys
import time

from playwright.sync_api import sync_playwright

VIEWPORT = {"width": 1600, "height": 1000}
GRID_VIEWPORT = {"width": 1600, "height": 470}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["grid", "page"])
    ap.add_argument("output")
    ap.add_argument("--alb-ip")
    ap.add_argument("--host", default="demo.example.com")
    ap.add_argument("--url")
    ap.add_argument("--settle", type=float, default=20)
    ap.add_argument("--full", action="store_true")
    ap.add_argument("--wait-selector")
    ap.add_argument("--height", type=int)
    args = ap.parse_args()

    launch_args = []
    if args.mode == "grid":
        if not args.alb_ip:
            sys.exit("grid mode needs --alb-ip")
        launch_args.append(f"--host-resolver-rules=MAP {args.host} {args.alb_ip}")
        url = f"http://{args.host}/"
    else:
        if not args.url:
            sys.exit("page mode needs --url")
        url = args.url

    with sync_playwright() as p:
        browser = p.chromium.launch(args=launch_args)
        viewport = dict(GRID_VIEWPORT if args.mode == "grid" else VIEWPORT)
        if args.height:
            viewport["height"] = args.height
        page = browser.new_context(viewport=viewport,
                                   device_scale_factor=2).new_page()
        page.goto(url, wait_until="domcontentloaded", timeout=60000)
        if args.wait_selector:
            page.wait_for_selector(args.wait_selector, timeout=60000)
        # The tile grid fills itself by polling, so it needs real wall-clock
        # time on screen before it is worth photographing.
        time.sleep(args.settle)
        png = page.screenshot(full_page=args.full)
        with open(args.output, "wb") as fh:
            fh.write(png)
        browser.close()
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
