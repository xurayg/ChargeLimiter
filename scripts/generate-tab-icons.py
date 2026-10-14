#!/usr/bin/env python3
"""Render the app's four template icons at 1x/2x/3x, including pre-SF-Symbol iOS."""
from pathlib import Path
import json
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parent.parent / 'ChargeLimiter/Assets.xcassets'
size = 28
oversample = 8

def draw_icon(name):
    canvas = Image.new('RGBA', (size*oversample, size*oversample), (0,0,0,0))
    draw = ImageDraw.Draw(canvas)
    ink = (0,0,0,255)
    def box(points): return tuple(round(v*oversample) for v in points)
    def line(points, width=1.8):
        draw.line([(round(x*oversample),round(y*oversample)) for x,y in points], fill=ink, width=round(width*oversample), joint='curve')
        r=width*oversample/2
        for x,y in [points[0],points[-1]]:
            cx,cy=x*oversample,y*oversample
            draw.ellipse((cx-r,cy-r,cx+r,cy+r),fill=ink)
    if name == 'TabCharging':
        draw.rounded_rectangle(box((2.5,7,24.2,21)), radius=round(2.5*oversample), outline=ink, width=round(1.8*oversample))
        draw.rounded_rectangle(box((25.1,11,27,17)), radius=oversample, fill=ink)
        draw.polygon([(round(x*oversample),round(y*oversample)) for x,y in [(14.6,8.7),(9.8,14.4),(13.3,14.4),(11.8,19.2),(17.3,12.7),(13.8,12.7)]],fill=ink)
    elif name == 'TabSettings':
        for y,x in [(6,9),(14,19),(22,12)]:
            line([(3,y),(x-3,y)]); line([(x+3,y),(25,y)])
            draw.ellipse(box((x-3,y-3,x+3,y+3)),outline=ink,width=round(1.8*oversample))
    elif name == 'TabHistory':
        line([(4,3),(4,24),(25,24)])
        line([(7,19),(12,13),(17,16),(24,7)],2)
        for x,y in [(7,19),(12,13),(17,16),(24,7)]:
            draw.ellipse(box((x-1.5,y-1.5,x+1.5,y+1.5)),fill=ink)
    else:
        draw.rounded_rectangle(box((4,2.5,21,25)),radius=round(2.2*oversample),outline=ink,width=round(1.8*oversample))
        for y in [7,11]: line([(8,y),(17,y)],1.6)
        # Cut out the overlapping document border before drawing the magnifier.
        draw.ellipse(box((12,12,25,25)),fill=(0,0,0,0))
        draw.ellipse(box((13.5,13.5,23.5,23.5)),outline=ink,width=round(1.8*oversample))
        line([(22.2,22.2),(26,26)],2)
    return canvas

for name in ['TabCharging','TabSettings','TabHistory','TabDiagnostics']:
    folder=root/(name+'.imageset'); folder.mkdir(parents=True,exist_ok=True)
    artwork=draw_icon(name)
    entries=[]
    for scale in (1,2,3):
        filename=f'{name}@{scale}x.png'
        artwork.resize((size*scale,size*scale), Image.Resampling.LANCZOS).save(folder/filename)
        entries.append(dict(idiom='universal',filename=filename,scale=f'{scale}x'))
    (folder/'Contents.json').write_text(json.dumps(dict(images=entries,info=dict(author='xcode',version=1),properties={'template-rendering-intent':'template'}),indent=2)+'\n')
print('Generated four 28-point template icons at 1x, 2x and 3x.')
