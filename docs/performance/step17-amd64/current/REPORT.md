# Step 17 performance and resource measurements

Measurement mode: single serial HTTP/1.1 client, persistent connection.
Client-side latency includes Python overhead; **not** server-only latency or peak RPS.

- Source: `current`
- Captured UTC: 2026-10-26T23:37:24.110715+00:00
- Architecture: x86_64
- Git HEAD: `1efc60a397aa7bb8ec0f38dec9beb1436172bf57`
- Binary size: 806000 bytes

| Route | Run | Req | RPS | p50 (ms) | p99 (ms) | Process CPU (s) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| plain | 1 | 400 | 19055.48 | 0.0447 | 0.1713 | 0.0000 |
| plain | 2 | 400 | 19782.59 | 0.0450 | 0.1136 | 0.0200 |
| plain | 3 | 400 | 21943.24 | 0.0444 | 0.0563 | 0.0100 |
| json | 1 | 400 | 17968.10 | 0.0453 | 0.2226 | 0.0000 |
| json | 2 | 400 | 19954.84 | 0.0445 | 0.0943 | 0.0100 |
| json | 3 | 400 | 17780.73 | 0.0458 | 0.2276 | 0.0200 |
| query | 1 | 400 | 21966.72 | 0.0445 | 0.0565 | 0.0000 |
| query | 2 | 400 | 21758.88 | 0.0447 | 0.0558 | 0.0100 |
| query | 3 | 400 | 19506.63 | 0.0447 | 0.1624 | 0.0200 |
| post | 1 | 400 | 17968.12 | 0.0542 | 0.0713 | 0.0000 |
| post | 2 | 400 | 15773.77 | 0.0543 | 0.1749 | 0.0200 |
| post | 3 | 400 | 16651.06 | 0.0539 | 0.1851 | 0.0100 |
| static_small | 1 | 400 | 24.31 | 41.0945 | 42.4143 | 0.1200 |
| static_small | 2 | 400 | 24.33 | 41.0593 | 42.1684 | 0.1200 |
| static_small | 3 | 400 | 24.34 | 41.0700 | 42.2646 | 0.1400 |
| static_large | 1 | 10 | 96.29 | 2.1544 | 43.3865 | 0.0100 |
| static_large | 2 | 10 | 69.86 | 2.3137 | 43.9134 | 0.0100 |
| static_large | 3 | 10 | 98.75 | 2.0061 | 43.5458 | 0.0200 |
| static_huge | 1 | 2 | 47.27 | 21.1515 | 23.4252 | 0.0300 |
| static_huge | 2 | 2 | 49.12 | 20.3568 | 21.4388 | 0.0400 |
| static_huge | 3 | 2 | 47.96 | 20.8464 | 22.4776 | 0.0300 |

## Process checkpoints

| Phase | RSS (KiB) | HWM (KiB) | FDs |
| --- | ---: | ---: | ---: |
| ready | 2692 | 2692 | 5 |
| after_1000_requests | 2696 | 2696 | 5 |
| after_plain | 2712 | 2712 | 5 |
| after_json | 2728 | 2728 | 5 |
| after_query | 2740 | 2740 | 5 |
| after_post | 2748 | 2748 | 5 |
| after_static_small | 2768 | 2768 | 5 |
| after_static_large | 2828 | 2828 | 5 |
| after_static_huge | 2828 | 2828 | 5 |

Reported HWM is a process lifetime high-water mark, not per-route memory use.
Release acceptance also requires security tests and a real ARM hardware run.
