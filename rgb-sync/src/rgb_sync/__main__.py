"""rgb-sync CLI.

  rgb-sync run            screen sync loop (what the systemd unit runs)
  rgb-sync show COLOR     put one calibrated color on fans + soundbar (calibration)
  rgb-sync probe          print the source that would be used and one frame's LED colors
"""

import argparse
import logging
from pathlib import Path

from . import config as config_mod


def main():
    parser = argparse.ArgumentParser(prog="rgb-sync")
    parser.add_argument("--config", type=Path, default=None)
    sub = parser.add_subparsers(dest="cmd")
    sub.add_parser("run")
    show = sub.add_parser("show")
    show.add_argument("color", help="hex color, e.g. #8000ff")
    sub.add_parser("probe")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    cfg = config_mod.load(args.config)

    if args.cmd == "show":
        from .output import Output

        out = Output(cfg)
        out.fill(config_mod.parse_hex(args.color))
        out.close()
    elif args.cmd == "probe":
        from .service import Service

        svc = Service(cfg)
        kind, cap, session = svc._open_source()
        if cap is None:
            print("no capture source available")
            return
        frame = None
        try:
            cap.start()
            for _ in range(40):
                frame = cap.pull(0.25)
                if frame is not None:
                    break
        finally:
            cap.stop()
            if session:
                session.close()
        print(f"source: {kind}, frame: {None if frame is None else frame.shape}")
        if frame is not None:
            print("fans:", svc.fan_sampler.sample(frame).round().astype(int).tolist())
            print("soundbar:", svc.bar_sampler.sample(frame).round().astype(int).tolist())
    else:
        from .service import Service

        Service(cfg).run()


if __name__ == "__main__":
    main()
