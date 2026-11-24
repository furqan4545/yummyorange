"""Model-free measurements of a tick WAV (no earshot models needed). Usage: python metrics.py a.wav [b.wav ...]
Prints: rms dBFS, crest dB, attack ms (onset to peak), fall times to -20/-30/-40 dB of peak (2 ms max windows),
tonal peak ratio dB (strongest FFT bin over median bin, high = ringing tones), spectral centroid Hz, and energy
share dB in bands 0-250, 250-1k, 1-3k, 3-6k, 6-12k, 12-24k Hz."""
import sys, numpy as np, soundfile as sf
def metrics(p):
    x, sr = sf.read(p); x = x if x.ndim == 1 else x[:, 0]
    pk = np.abs(x).max(); rms = np.sqrt((x ** 2).mean())
    w = int(0.002 * sr); e = np.array([np.abs(x[i:i + w]).max() for i in range(0, len(x) - w + 1, w)])
    def fall(db):
        idx = np.where(e > pk * 10 ** (db / 20))[0]; return float((idx.max() + 1) * 2) if len(idx) else 0.0
    onset = np.argmax(np.abs(x) > pk * 0.1); peak_i = np.argmax(np.abs(x))
    X = np.abs(np.fft.rfft(x, 1 << 16)) ** 2; f = np.fft.rfftfreq(1 << 16, 1 / sr); tot = X.sum()
    share = {f'{a}-{b}': round(float(10 * np.log10(X[(f >= a) & (f < b)].sum() / tot + 1e-12)), 1)
             for a, b in [(0, 250), (250, 1000), (1000, 3000), (3000, 6000), (6000, 12000), (12000, 24000)]}
    mag = np.sqrt(X[(f > 100) & (f < 16000)])
    return dict(rms_dbfs=round(float(20 * np.log10(rms)), 1), crest_db=round(float(20 * np.log10(pk / rms)), 1),
                attack_ms=round(float((peak_i - onset) / sr * 1000), 1), fall_ms=(fall(-20), fall(-30), fall(-40)),
                tonal_peak_db=round(float(20 * np.log10(mag.max() / np.median(mag))), 1),
                centroid_hz=int((f * X).sum() / tot), bands=share, length_ms=round(len(x) / sr * 1000, 1))
if __name__ == '__main__':
    for p in sys.argv[1:]: print(p.split('/')[-1], metrics(p))
