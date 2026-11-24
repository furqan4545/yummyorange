"""A sweep preview mixed exactly like the app plays it (PetalSound.plan + moveSamples + varispeed resampling).
Usage from Python: sweep.write_sweep(recipe, path). The sweep: slow, speeding to ~22 petals/s with skipped petals,
then slowing down (the same moves as the app's --petal-sounds preview)."""
import math, struct, wave
import softlib
SR = 48000.0
MOVES = [(0.4, 1)] * 3 + [(i, 1) for i in [0.25, 0.18, 0.13, 0.1, 0.08, 0.065, 0.055]] + [(0.045, 1)] * 14 \
        + [(0.05, 2), (0.05, 3), (0.05, 2)] + [(i, 1) for i in [0.055, 0.07, 0.09, 0.12, 0.16, 0.22, 0.32, 0.45]]
def plan(steps, interval, move_time=None):
    n = max(1, min(steps, 6)); span = interval if (math.isfinite(interval) and interval > 0) else 1
    pps = max(1, steps) / span; x = min(max((pps - 5) / 15, 0), 1); e = x * x * (3 - 2 * x)
    rate = 1 + 0.3 * e; vol = 1 - 0.2 * e
    mv = move_time if (move_time and math.isfinite(move_time) and move_time > 0) else span
    sp = min(max(mv / n, 0.012), 0.04)
    if n > 1: sp = min(sp, 0.1 / (n - 1))
    return [(k * sp, rate, vol) for k in range(n)]
def move_samples(one, pl):
    rate = pl[0][1]; offs = [int(round(d * rate * SR)) for d, _, _ in pl]
    out = [0.0] * (max(offs) + len(one))
    for o in offs:
        for i, v in enumerate(one): out[o + i] += v
    return out
def sweep(one, moves=MOVES):
    events = []; t = 0.3
    for iv, st in moves:
        t += iv; events.append((t, plan(st, iv)))
    out = [0.0] * int((t + 0.5) * SR)
    for et, pl in events:
        src = one if len(pl) == 1 else move_samples(one, pl)
        start = int(et * SR); rate, vol = pl[0][1], pl[0][2]; pos = 0.0; i = 0
        while int(pos) + 1 < len(src) and start + i < len(out):
            k = int(pos); fr = pos - k
            out[start + i] += (src[k] * (1 - fr) + src[k + 1] * fr) * vol; pos += rate; i += 1
    return out
def write_sweep(recipe, path):
    x = sweep(softlib.render(recipe))
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(int(SR))
        w.writeframes(b"".join(struct.pack("<h", int(round(max(-1, min(1, v)) * 32767))) for v in x))
