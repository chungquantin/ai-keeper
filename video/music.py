"""Synthesizes the 30 second soundtrack for the launch film. Pure Python, no dependencies.
Happy and bouncy: C major, 120 BPM, a marimba hook over C-G-Am-F, offbeat chord stabs, a syncopated bass, claps and shakers.
The arrangement follows the film: sparse intro and riser, the drop at 4s when the robots arrive, a lighter middle for the demo,
a breakdown for the history chart, a lift for the tools and a bright ending on the end card.
Usage: python3 music.py out.wav"""
import math, random, struct, sys, wave

SR = 44100; DUR = 30.0; BPM = 120
N = int(SR * DUR)
spb = 60 / BPM          # one beat = 0.5s
e8 = spb / 2            # eighth
s16 = spb / 4           # sixteenth
L = [0.0] * N; R = [0.0] * N        # dry bus
WL = [0.0] * N; WR = [0.0] * N      # bus that gets echo
random.seed(11)

def hz(m): return 440.0 * 2 ** ((m - 69) / 12)

def put(t0, dur, f, partials, vol, pan=0.0, wet=0.0, attack=0.004, decay=3.0, vib=0.0, glide=0.0):
    """Adds one note. partials = [(multiple, level)...]. Exponential decay, optional vibrato and pitch glide."""
    i0 = int(t0 * SR); n = int(dur * SR)
    if i0 >= N: return
    n = min(n, N - i0)
    lg, rg = math.cos((pan + 1) * math.pi / 4), math.sin((pan + 1) * math.pi / 4)
    ph = 0.0
    for k in range(n):
        t = k / SR
        env = min(1.0, t / attack) * math.exp(-decay * t / dur) * min(1.0, (dur - t) / 0.02 if dur - t < 0.02 else 1.0)
        ff = f * (1 + vib * math.sin(2 * math.pi * 5.5 * t)) * (1 + glide * (1 - t / dur))
        ph += 2 * math.pi * ff / SR
        v = 0.0
        for m, lv in partials: v += math.sin(ph * m) * lv
        v *= env * vol
        L[i0 + k] += v * lg * (1 - wet); R[i0 + k] += v * rg * (1 - wet)
        if wet: WL[i0 + k] += v * lg * wet; WR[i0 + k] += v * rg * wet

MARIMBA = [(1, 1.0), (4, .35), (10, .08)]
BELL = [(1, 1.0), (2.76, .35), (5.4, .15), (8.93, .08)]
EP = [(1, 1.0), (2, .45), (3, .18), (4, .08)]       # soft electric piano
BASS = [(1, 1.0), (2, .35), (3, .12)]
PAD = [(1, 1.0), (2, .3), (3, .15)]

def noise_burst(t0, dur, vol, pan=0.0, hp=True, decay=6.0, wet=0.0):
    i0 = int(t0 * SR); n = min(int(dur * SR), N - i0)
    if i0 >= N or n <= 0: return
    lg, rg = math.cos((pan + 1) * math.pi / 4), math.sin((pan + 1) * math.pi / 4)
    prev = 0.0
    for k in range(n):
        x = random.random() * 2 - 1
        v = (x - prev) if hp else x; prev = x
        v *= vol * math.exp(-decay * k / n) * min(1.0, k / (SR * .0015))
        L[i0 + k] += v * lg * (1 - wet); R[i0 + k] += v * rg * (1 - wet)
        if wet: WL[i0 + k] += v * lg * wet; WR[i0 + k] += v * rg * wet

def kick(t0, vol=.85):
    i0 = int(t0 * SR); n = int(.22 * SR)
    for k in range(n):
        if i0 + k >= N: break
        t = k / SR; f = 48 + 130 * math.exp(-t * 28)
        v = math.sin(2 * math.pi * f * t) * math.exp(-t * 13) * vol + (random.random() * 2 - 1) * math.exp(-t * 120) * .15
        L[i0 + k] += v; R[i0 + k] += v

def clap(t0, vol=.5):
    for d in (0, .011, .022):
        noise_burst(t0 + d, .09, vol * (1 if d == .022 else .6), hp=False, decay=9, wet=.18)

def hat(t0, vol=.16, pan=.3, long=False): noise_burst(t0, .13 if long else .035, vol, pan, decay=5 if long else 8)
def shaker(t0, vol=.07, pan=-.3): noise_burst(t0, .05, vol, pan, decay=6)

def riser(t0, t1, vol=.22):
    n = int((t1 - t0) * SR); i0 = int(t0 * SR); prev = 0.0; ph = 0.0
    for k in range(n):
        if i0 + k >= N: break
        p = k / n; x = random.random() * 2 - 1; v = (x - prev) * (p ** 2) * vol; prev = x
        ph += 2 * math.pi * (300 + 1700 * p * p) / SR
        v += math.sin(ph) * p * p * vol * .5
        L[i0 + k] += v; R[i0 + k] += v

def whoosh(t0, t1, vol=.16):
    n = int((t1 - t0) * SR); i0 = int(t0 * SR); prev = 0.0
    for k in range(n):
        if i0 + k >= N: break
        p = k / n; env = math.sin(math.pi * p) ** 1.5; x = random.random() * 2 - 1; v = (x - prev) * env * vol; prev = x
        pan = -1 + 2 * p; L[i0 + k] += v * (1 - p); R[i0 + k] += v * p

# ---------------- arrangement ----------------
CH = [(48, [0, 4, 7]), (55, [0, 4, 7]), (57, [0, 3, 7]), (53, [0, 4, 7])]   # C, G, Am, F  (root, triad)
# melody, eighth notes, 0 = rest. Pattern A is the hook, pattern B a lifted answer.
MA = [[79, 0, 76, 79, 84, 0, 79, 76], [79, 0, 74, 79, 83, 0, 79, 74], [76, 0, 72, 76, 81, 0, 76, 72], [77, 0, 72, 77, 84, 0, 81, 77]]
MB = [[84, 79, 76, 79, 84, 0, 88, 0], [83, 79, 74, 79, 83, 0, 86, 0], [81, 76, 72, 76, 81, 0, 84, 0], [84, 81, 77, 81, 84, 0, 89, 0]]
BASSP = [0, 0, 12, 0, 0, 7, 0, 12]          # eighth-note offsets from the root; 0 held, syncopated

def swing(i): return .022 if i % 2 else 0     # a little bounce on the off-eighths

for bar in range(15):
    t = bar * 4 * spb
    root, tri = CH[bar % 4]
    full = 2 <= bar <= 13                     # from the drop to the end card
    breakdown = 10 <= bar <= 11               # history chart: no kick, no bass, lead and claps
    lighter = 5 <= bar <= 6                   # demo scenes: groove without the lead
    # soft pad under everything
    for m in tri: put(t, 4 * spb, hz(root + 12 + m), PAD, .045 if bar < 2 else .05, pan=(m - 4) / 14, wet=.5, attack=.25, decay=.7)
    if bar < 2:
        # intro: marimba arpeggio, shaker, a heartbeat of kick
        for i in range(8):
            put(t + i * e8 + swing(i), e8 * 1.7, hz(root + 24 + tri[i % 3]), MARIMBA, .13, pan=-.25 + .1 * (i % 3), wet=.35, decay=4)
            shaker(t + i * e8 + swing(i), .05)
        if bar == 1:
            for i in range(4): kick(t + i * spb, .45 * (i + 1) / 4)
    if full:
        for i in range(8):
            ti = t + i * e8
            if not breakdown and bar >= 2:
                if i % 2 == 0: kick(ti) if (i % 2 == 0 and (i // 2) in (0, 1, 2, 3)) else None
            # hats on the off-eighths, shakers on the sixteenths
            hat(ti + e8 / 2 + swing(1), .14 if i % 2 else .1, pan=.35, long=(i % 4 == 3))
            shaker(ti, .06); shaker(ti + s16, .05)
        for b in (1, 3): clap(t + b * spb, .5 if not breakdown else .4)
        # bass
        if not breakdown:
            for i, off in enumerate(BASSP):
                if i in (0, 2, 3, 5, 7):
                    put(t + i * e8, e8 * (1.6 if i in (0, 5) else .9), hz(root - 12 + (off if off in (0, 12, 7) else 0)), BASS, .36, wet=0, decay=2.2)
        # electric piano stabs on the off-beats
        for i in (1, 3, 5, 7):
            for m in tri: put(t + i * e8 + swing(1), e8 * 1.3, hz(root + 12 + m), EP, .045, pan=.2, wet=.3, decay=5)
    # lead
    pattern = MA if (bar // 4) % 2 == 0 else MB
    if (full and not lighter and not (bar == 13)) or bar in (14,):
        if bar >= 12: pattern = MB
        for i, n in enumerate(pattern[bar % 4]):
            if n and not (breakdown and False):
                put(t + i * e8 + swing(i), e8 * 1.9, hz(n), MARIMBA, .17, pan=.1, wet=.4, decay=3.6)
                if bar >= 8 and n: put(t + i * e8 + swing(i), e8 * 1.4, hz(n + 12), BELL, .035, pan=-.1, wet=.5, decay=5)
    # sparkle: climbing bell run while the robots clear the floor (4s to 9s)
    if bar in (2, 3, 4):
        for i in range(8):
            put(t + i * e8, e8 * 1.5, hz(84 + [0, 4, 7, 12, 7, 4, 12, 16][(i + bar) % 8] - (12 if bar == 4 else 0)), BELL, .05, pan=[-.5, .5][i % 2], wet=.6, decay=5)

# the 3 to 4 second build into the drop
riser(2.6, 4.0, .2)
for i in range(8): clap(3.0 + i * .125 + (0 if i < 4 else 0), .18 + i * .045) if i % 2 == 0 else noise_burst(3.0 + i * .125, .06, .12 + i * .03, hp=False, decay=8)
# whooshes and a pop on each scene change (the film's wipes)
for a, b in ((9.2, 10.0), (14.9, 15.7), (19.9, 20.7), (24.9, 25.7)):
    whoosh(a, b, .17); put((a + b) / 2, .5, hz(91), BELL, .08, wet=.6, decay=4)
# "+107.9 GB" lands
for k, n in enumerate((84, 88, 91, 96)): put(8.55 + k * .08, .6, hz(n), BELL, .08, pan=.2 * (k - 1.5), wet=.6, decay=4)
# the end card: a big, happy C major chord and a glittering run, then a soft ring out
for m in (60, 64, 67, 72, 76): put(28.0, 1.9, hz(m), EP, .08, pan=(m - 66) / 20, wet=.4, decay=2.2)
put(28.0, 1.9, hz(36), BASS, .4, decay=2.0)
kick(28.0, .9); clap(28.0, .5)
for k, n in enumerate((72, 76, 79, 84, 88, 91, 96)): put(28.05 + k * .06, 1.4, hz(n), BELL, .07, pan=-.5 + k / 7, wet=.6, decay=3)

# ---------------- echo on the wet bus (ping-pong, dotted eighth) ----------------
d1 = int(e8 * 1.5 * SR); taps = [(1, .42, 0), (2, .26, 1), (3, .16, 0), (4, .09, 1)]
for rep, g, swap in taps:
    off = d1 * rep
    for i in range(N - off):
        s = (WL[i] + WR[i]) * .5 * g
        if swap: L[i + off] += s * 1.2; R[i + off] += s * .8
        else: L[i + off] += s * .8; R[i + off] += s * 1.2
for i in range(N): L[i] += WL[i]; R[i] += WR[i]

# ---------------- master ----------------
for i in range(N):
    x = i / SR; g = min(1.0, x / .35) * min(1.0, (DUR - x) / 1.2) if x > DUR - 1.2 else min(1.0, x / .35)
    L[i] = math.tanh(L[i] * g * 1.25); R[i] = math.tanh(R[i] * g * 1.25)
peak = max(max(abs(v) for v in L), max(abs(v) for v in R)) or 1
sc = 0.82 * 32767 / peak
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
w.writeframes(b''.join(struct.pack('<hh', int(L[i] * sc), int(R[i] * sc)) for i in range(N))); w.close()
