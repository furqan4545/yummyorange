"""Sound kit for YummyOrange petal sounds. Mirrors PetalSound's synthesis in ThemeSound.swift exactly (same LCG noise,
same maths, double precision), so a recipe made here renders identically in the app once ported.

A recipe is a dict:
  {"length": seconds, "level": peak level 0..1 relative to 0.14 (default 1), "seed": int (default 0x5EEDD1A1),
   "calls": [ {"fn": "strike", ...}, {"fn": "thump", ...}, ... ],
   "post_lowpass": Hz or 0 (one-pole lowpass over the whole tick, default 0)}
strike: t0, gain, rise=0.0004, burst, noise, tilt=0 (int 0..2), lowpass=0, highpass=0, modes=[[f, decay, amp], ...]
   A noise burst (white, LCG) whose envelope decays with time constant `burst`, made brighter by `tilt` first
   differences (x0.7 each), then high-passed (one-pole, `highpass` Hz, 0 = off) and low-passed (one-pole, `lowpass`
   Hz, 0 = off, with make-up gain sqrt(1+20000/lowpass)*0.5), plus damped sine modes; all rise over `rise` seconds
   (sine-squared). Rendered for 7x the longest time constant (or to the end of the buffer).
thump: t0, gain, f0, f1, ftau, decay, rise=0.001
   A sine whose pitch glides from f0 to f1 with time constant ftau, envelope rising over `rise` (sine-squared) and
   decaying with time constant `decay`. Rendered for 7x decay.
Then a 2 ms linear fade at the end, and peak normalisation to 0.14 x level.
render(recipe) -> list of floats at 48 kHz.  write(recipe, path) writes 16-bit mono 48 kHz WAV.
"""
import math, struct, wave
SR = 48000.0
PEAK = 0.14
MASK = (1 << 64) - 1

class Noise:
    def __init__(self, seed): self.s = seed & MASK
    def white(self):
        self.s = (self.s * 6364136223846793005 + 1442695040888963407) & MASK
        return float(self.s >> 11) / float(1 << 53) * 2 - 1

def _ramp(t, rise):
    return math.pow(math.sin(math.pi / 2 * t / rise), 2) if (rise > 0 and t < rise) else 1.0

def strike(out, rng, t0, gain, burst, noise, rise=0.0004, tilt=0, lowpass=0.0, highpass=0.0, modes=()):
    start = int(t0 * SR)
    longest = max([m[1] for m in modes]) if modes else burst
    length = min(len(out) - start, int(max(longest, burst) * 7 * SR))
    if length <= 0: return
    previous = [0.0] * (tilt + 1)
    for k in range(tilt + 1): previous[k] = rng.white() if k == 0 else 0.0
    a = 1 - math.exp(-2 * math.pi * lowpass / SR) if lowpass > 0 else 1.0
    make_up = math.sqrt(1 + 20000 / lowpass) * 0.5 if lowpass > 0 else 1.0
    ah = 1 - math.exp(-2 * math.pi * highpass / SR) if highpass > 0 else 0.0
    smooth = 0.0; hp_state = 0.0
    for i in range(length):
        t = i / SR
        w = rng.white()
        for k in range(tilt):
            d = (w - previous[k]) * 0.7; previous[k] = w; w = d
        if highpass > 0:
            hp_state += ah * (w - hp_state); w = w - hp_state
        smooth += a * (w - smooth)
        r = _ramp(t, rise)
        v = noise * smooth * make_up * math.exp(-t / burst) * r
        for (f, d, amp) in modes:
            v += amp * r * math.exp(-t / d) * math.sin(2 * math.pi * f * t + f * 0.0007)
        out[start + i] += gain * v

def thump(out, t0, gain, f0, f1, ftau, decay, rise=0.001):
    start = int(t0 * SR)
    length = min(len(out) - start, int(decay * 7 * SR))
    phase = 0.0
    for i in range(max(0, length)):
        t = i / SR
        f = f1 + (f0 - f1) * math.exp(-t / ftau)
        phase += 2 * math.pi * f / SR
        out[start + i] += gain * _ramp(t, rise) * math.exp(-t / decay) * math.sin(phase)

def render(recipe):
    out = [0.0] * int(recipe["length"] * SR)
    rng = Noise(recipe.get("seed", 0x5EEDD1A1))
    for c in recipe["calls"]:
        c = dict(c); fn = c.pop("fn")
        if fn == "strike": strike(out, rng, **c)
        elif fn == "thump": thump(out, **c)
        else: raise ValueError(fn)
    lp = recipe.get("post_lowpass", 0)
    if lp:
        a = 1 - math.exp(-2 * math.pi * lp / SR); y = 0.0
        for i in range(len(out)): y += a * (out[i] - y); out[i] = y
    fade = int(0.002 * SR)
    for i in range(min(fade, len(out))): out[len(out) - 1 - i] *= i / fade
    top = max(abs(v) for v in out) or 1.0
    level = PEAK * recipe.get("level", 1.0)
    return [v / top * level for v in out]

def write(recipe, path):
    x = render(recipe)
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(int(SR))
        w.writeframes(b"".join(struct.pack("<h", int(round(max(-1, min(1, v)) * 32767))) for v in x))
    return x
