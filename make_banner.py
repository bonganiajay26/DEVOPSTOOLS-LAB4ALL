"""
LinkedIn Banner Generator — DevOps + MLOps + AIOps Mastery Repo
Output: linkedin_banner.png  (1200 x 630 px)
"""

from PIL import Image, ImageDraw, ImageFont
import math, os, sys

W, H = 1200, 630

# ── Palette ───────────────────────────────────────────────────
BG          = (13,  17,  23)        # GitHub dark
GRID_LINE   = (22,  31,  43)
CARD_BG     = (22,  31,  43)
CARD_BORDER = (30,  44,  60)
GREEN       = (0,   210, 106)       # accent
CYAN        = (56,  189, 248)
PURPLE      = (167, 139, 250)
ORANGE      = (251, 146,  60)
PINK        = (236,  72, 153)
WHITE       = (255, 255, 255)
GREY        = (139, 148, 158)
DARK_GREY   = (48,  54,  61)

# ── Font helper ───────────────────────────────────────────────
def font(size, bold=False):
    candidates = [
        r"C:\Windows\Fonts\segoeui.ttf"  if not bold else r"C:\Windows\Fonts\segoeuib.ttf",
        r"C:\Windows\Fonts\arial.ttf"    if not bold else r"C:\Windows\Fonts\arialbd.ttf",
        r"C:\Windows\Fonts\consola.ttf",
        r"C:\Windows\Fonts\cour.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except:
                pass
    return ImageFont.load_default()

# ── Canvas ────────────────────────────────────────────────────
img  = Image.new("RGB", (W, H), BG)
draw = ImageDraw.Draw(img)

# ── Background grid (subtle) ──────────────────────────────────
for x in range(0, W, 40):
    draw.line([(x, 0), (x, H)], fill=GRID_LINE, width=1)
for y in range(0, H, 40):
    draw.line([(0, y), (W, y)], fill=GRID_LINE, width=1)

# ── Top gradient band (dark-blue → transparent) ──────────────
for y in range(120):
    alpha = int(180 * (1 - y/120))
    r = int(13 + (20-13)*(1 - y/120))
    g = int(17 + (40-17)*(1 - y/120))
    b = int(23 + (80-23)*(1 - y/120))
    draw.line([(0, y), (W, y)], fill=(r, g, b))

# ── Bottom gradient band ──────────────────────────────────────
for i in range(80):
    y = H - 80 + i
    frac = i / 80
    r = int(13 + (0 -13)*frac)
    g = int(17 + (30-17)*frac)
    b = int(23 + (60-23)*frac)
    draw.line([(0, y), (W, y)], fill=(r, g, b))

# ── Green glow blob (top-right) ───────────────────────────────
for r in range(200, 0, -1):
    alpha = int(18 * (r/200)**2)
    col   = (0, min(255,alpha+10), min(100, alpha+40))
    draw.ellipse([W-r-40, -r//2, W-40+r, r], outline=col)

# ── Purple glow blob (bottom-left) ───────────────────────────
for r in range(160, 0, -1):
    alpha = int(15 * (r/160)**2)
    col   = (min(80,alpha+20), 0, min(120,alpha+40))
    draw.ellipse([-r//2, H-r, r, H+r//2], outline=col)

# ── Decorative circuit-trace lines ────────────────────────────
traces = [
    # (x1,y1,x2,y2)
    (900, 0,   900, 80),   (900, 80, 980, 80),  (980, 80,  980, 0),
    (60,  H,   60,  H-60), (60, H-60, 140, H-60),
    (1100, 300, 1160, 300), (1160, 300, 1160, 380), (1160, 380, 1100, 380),
    (40, 180, 80, 180),    (80, 180, 80, 220),
]
for x1,y1,x2,y2 in traces:
    draw.line([(x1,y1),(x2,y2)], fill=(0, 60, 40), width=1)
# Small dots at trace junctions
for x,y in [(900,80),(980,80),(60,H-60),(1160,300),(1160,380),(80,180)]:
    draw.ellipse([x-3,y-3,x+3,y+3], fill=(0,140,70))

# ── "GITHUB" top-right corner tag ────────────────────────────
tag_x, tag_y = W-160, 20
draw.rounded_rectangle([tag_x, tag_y, tag_x+140, tag_y+32],
                        radius=6, fill=(30,40,55), outline=(0,140,70), width=1)
draw.text((tag_x+16, tag_y+7), "⬡ Open Source", font=font(13), fill=GREEN)

# ── Star badge (top-left) ────────────────────────────────────
draw.rounded_rectangle([20, 20, 110, 52], radius=6,
                        fill=(22,31,43), outline=(56,189,248), width=1)
draw.text((28, 29), "★  Free", font=font(13, bold=True), fill=CYAN)

# ── MAIN TITLE ────────────────────────────────────────────────
title_y = 80
f_big   = font(62, bold=True)
f_mid   = font(22, bold=True)
f_small = font(15)
f_mono  = font(13)

# Coloured word rendering for title
words = [
    ("DevOps",  GREEN),
    (" + ",     GREY),
    ("MLOps",   CYAN),
    (" + ",     GREY),
    ("AIOps",   PURPLE),
]
cursor_x = 72
for word, color in words:
    draw.text((cursor_x, title_y), word, font=f_big, fill=color)
    bb = draw.textbbox((cursor_x, title_y), word, font=f_big)
    cursor_x = bb[2]

# Subtitle
sub = "Production-Grade Learning Repository for DevOps Engineers"
sb  = draw.textbbox((0,0), sub, font=f_mid)
sub_w = sb[2]-sb[0]
draw.text((72, title_y+72), sub, font=f_mid, fill=WHITE)

# Thin green underline below subtitle
draw.line([(72, title_y+100), (72+sub_w, title_y+100)], fill=GREEN, width=1)

# ── TECH BADGE GRID ───────────────────────────────────────────
badges = [
    # (label,       fill_color,   border_color)
    ("Git",           (40,30,20),  ORANGE),
    ("Docker",        (20,35,55),  CYAN),
    ("Kubernetes",    (20,30,55),  (100,170,255)),
    ("Helm",          (30,20,50),  PURPLE),
    ("Terraform",     (25,20,50),  (150,100,255)),
    ("Ansible",       (50,20,20),  (255,100,100)),
    ("GitHub Actions",(20,35,25),  GREEN),
    ("Prometheus",    (50,30,20),  ORANGE),
    ("Grafana",       (35,25,45),  (220,100,180)),
    ("SRE",           (20,40,35),  (0,200,160)),
    ("GitOps",        (25,35,30),  GREEN),
    ("ArgoCD",        (30,25,50),  (180,140,255)),
    ("AWS",           (45,35,20),  (255,180,60)),
    ("Azure",         (20,30,55),  (60,140,255)),
    ("GCP",           (20,40,30),  (60,200,100)),
    ("MLOps",         (40,20,45),  PINK),
    ("AIOps",         (35,20,50),  (200,100,255)),
    ("Platform Eng",  (20,35,40),  CYAN),
]

# Layout: 6 per row × 3 rows
BADGE_W, BADGE_H = 162, 34
PAD_X, PAD_Y     = 10, 8
START_X, START_Y = 72, 215
COLS             = 6

for i, (label, fill, border) in enumerate(badges):
    col = i % COLS
    row = i // COLS
    bx  = START_X + col*(BADGE_W + PAD_X)
    by  = START_Y + row*(BADGE_H + PAD_Y)

    # Card bg + border
    draw.rounded_rectangle([bx, by, bx+BADGE_W, by+BADGE_H],
                            radius=6, fill=fill, outline=border, width=1)

    # Dot accent
    draw.ellipse([bx+9, by+BADGE_H//2-4, bx+17, by+BADGE_H//2+4], fill=border)

    # Label text
    tf  = font(13, bold=True)
    tb  = draw.textbbox((0,0), label, font=tf)
    tw  = tb[2]-tb[0]
    tx  = bx + 24
    ty  = by + (BADGE_H - (tb[3]-tb[1]))//2
    draw.text((tx, ty), label, font=tf, fill=WHITE)

# ── FEATURE HIGHLIGHTS (below badge grid) ────────────────────
features = [
    (" Docs + Architecture", GREEN),
    (" Working Code Examples", CYAN),
    (" Hands-On Labs", PURPLE),
    (" Interview Prep Q&A", ORANGE),
    (" Beginner to Advanced", PINK),
]
feat_y   = START_Y + 3*(BADGE_H + PAD_Y) + 16
feat_x   = 72
for label, col in features:
    fw   = font(13, bold=True)
    fb   = draw.textbbox((0,0), label, font=fw)
    fw_  = fb[2]-fb[0] + 22
    draw.rounded_rectangle([feat_x, feat_y, feat_x+fw_, feat_y+26],
                            radius=13, fill=(col[0]//6, col[1]//6, col[2]//6),
                            outline=col, width=1)
    draw.text((feat_x+10, feat_y+5), label, font=fw, fill=col)
    feat_x += fw_ + 10

# Divider line
div_y = feat_y + 40
draw.line([(72, div_y), (W-72, div_y)], fill=(30,44,60), width=1)

# ── Quick-pitch line ──────────────────────────────────────────
pitch = "Everything you need to go from zero to production-ready DevOps engineer"
pf = font(16)
pb = draw.textbbox((0,0), pitch, font=pf)
pw = pb[2]-pb[0]
draw.text(((W-pw)//2, div_y+12), pitch, font=pf, fill=GREY)

# ── Three callout boxes ───────────────────────────────────────
callouts = [
    ("Kubernetes", "5 complete labs\nfrom zero to RBAC", CYAN),
    ("Terraform", "AWS + GCP + Azure\ninfra examples", PURPLE),
    ("CI/CD + GitOps", "GitHub Actions +\nArgoCD pipelines", GREEN),
]
box_w, box_h = 280, 58
box_y = div_y + 46
box_gap = 36
total_w = len(callouts)*(box_w+box_gap) - box_gap
box_start = (W - total_w)//2

for i, (title, desc, col) in enumerate(callouts):
    bx = box_start + i*(box_w+box_gap)
    draw.rounded_rectangle([bx, box_y, bx+box_w, box_y+box_h],
                            radius=8, fill=(col[0]//7, col[1]//7, col[2]//7),
                            outline=col, width=1)
    # Title
    tf2 = font(14, bold=True)
    draw.text((bx+12, box_y+6), title, font=tf2, fill=col)
    # Desc
    df  = font(12)
    for j, line in enumerate(desc.split("\n")):
        draw.text((bx+12, box_y+24+j*14), line, font=df, fill=GREY)

# ── STAT BAR ─────────────────────────────────────────────────
bar_y = H - 76
draw.rectangle([0, bar_y, W, bar_y+1], fill=(30,44,60))

stats = [
    ("187", "Files"),
    ("70,000+", "Lines of Code"),
    ("18", "Topics Covered"),
    ("250+", "Labs & Examples"),
    ("300+", "Interview Q&A"),
]
seg_w = W // len(stats)
for i, (num, label) in enumerate(stats):
    cx = i * seg_w + seg_w//2
    # Number
    nf  = font(26, bold=True)
    nb  = draw.textbbox((0,0), num, font=nf)
    nw  = nb[2]-nb[0]
    draw.text((cx - nw//2, bar_y+10), num, font=nf, fill=GREEN)
    # Label
    lf  = font(12)
    lb  = draw.textbbox((0,0), label, font=lf)
    lw  = lb[2]-lb[0]
    draw.text((cx - lw//2, bar_y+40), label, font=lf, fill=GREY)
    # Divider
    if i > 0:
        draw.line([(i*seg_w, bar_y+12),(i*seg_w, bar_y+60)], fill=DARK_GREY, width=1)

# ── Bottom tagline ────────────────────────────────────────────
tag = "github.com/bonganiajay26/DEVOPSTOOLS-LAB4ALL"
tf  = font(14)
tb  = draw.textbbox((0,0), tag, font=tf)
tw  = tb[2]-tb[0]
draw.text(((W-tw)//2, H-20), tag, font=tf, fill=DARK_GREY)

# ── Save ─────────────────────────────────────────────────────
out = r"C:\Users\ajayd\DEVOPSTOOLS-LAB4ALL\linkedin_banner.png"
img.save(out, "PNG", dpi=(150,150))
print(f"[OK] Banner saved -> {out}")
print(f"   Size: {W}x{H}px")
