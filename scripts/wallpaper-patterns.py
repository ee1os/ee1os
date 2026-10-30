#!/usr/bin/env python3
# Draws the four pattern wallpapers in frameworks/base packages/Ee1osWallpapers (wp_contours,
# wp_steps, wp_red_contours, wp_glow as p1..p4.jpg; convert to WebP for the package).
#   wallpaper-patterns.py <out dir> [width height]   (1344 2992 = Pixel 8 Pro)
import numpy as np, sys
from PIL import Image, ImageFilter
W,H=(int(sys.argv[2]),int(sys.argv[3])) if len(sys.argv)>3 else (1344,2992)
out=sys.argv[1]
rng=np.random.default_rng(7)
y,x=np.mgrid[0:H,0:W]/W
def field(seed,n=6,s=1.0):
    r=np.random.default_rng(seed); f=np.zeros((H,W))
    for _ in range(n):
        cx,cy=r.uniform(0,1),r.uniform(0,H/W); a=r.uniform(.2,.6)*s
        f+=r.uniform(-1,1)*np.exp(-((x-cx)**2+(y-cy)**2)/(2*a*a))
    return f
def lerp(c1,c2,t): t=t[...,None]; return np.array(c1)*(1-t)+np.array(c2)*t
def save(a,name,blur=0):
    im=Image.fromarray(np.clip(a,0,255).astype('uint8'))
    if blur: im=im.filter(ImageFilter.GaussianBlur(blur))
    im.save(f"{out}/{name}.jpg",quality=86)
# p1: topographic contours, everyday (cool)
f=field(3,9); t=(f-f.min())/(f.max()-f.min())
base=lerp((14,26,44),(52,94,120),t)
lines=np.abs(np.sin(t*np.pi*22))<0.06
base[lines]=base[lines]*0.4+np.array([170,205,220])*0.6
save(base,"p1")
# p2: soft gradient bands, everyday (light)
f=field(11,7); t=(f-f.min())/(f.max()-f.min())
t=np.round(t*7)/7
save(lerp((214,226,232),(96,140,160),t),"p2",blur=2)
# p3: protected, dark with red contours
f=field(5,9); t=(f-f.min())/(f.max()-f.min())
base=lerp((8,6,8),(36,10,14),t)
lines=np.abs(np.sin(t*np.pi*18))<0.05
base[lines]=np.array([170,30,40])*(0.4+0.6*t[lines,None])
save(base,"p3")
# p4: protected, ember glow from below + grain
g=np.exp(-((x-.5)**2*3+(y-H/W*1.05)**2*1.4)); t=np.clip(g,0,1)
base=lerp((6,4,6),(150,28,24),t**1.6)
base+=rng.normal(0,5,base.shape)
save(base,"p4")
