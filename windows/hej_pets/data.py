from __future__ import annotations

import copy
import json
import math
import os
import random
import sys
import uuid
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageOps
from pillow_heif import register_heif_opener

register_heif_opener()
Image.MAX_IMAGE_PIXELS = 50_000_000
ACTIONS = {'dockCrawl': '任务栏爬行', 'perimeter': '沿屏幕四周', 'dance': '站立跳舞',
           'hop': '跳来跳去', 'mixed': '随机动作'}
DEFAULTS = dict(mode='random', fixedMinutes=2., randomMinMinutes=1., randomMaxMinutes=4.,
                messages=['陪你一会儿呀', '今天也很可爱', '摸摸我嘛', '休息一下吧'],
                dragMessages=['呀！轻一点～', '我要飞走啦！', '放我下来嘛', '抓稳我哦！'],
                animationFPS=30, actionMode='mixed', faceTrackingEnabled=True)


def clamp(v, low, high):
    return min(high, max(low, v))


def data_root():
    override = os.environ.get('HEJPETS_DATA_DIR')
    if override:
        return Path(override)
    if sys.platform == 'win32':
        return Path(os.environ['LOCALAPPDATA']) / 'HejPets'
    return Path.home() / 'Library' / 'Application Support' / 'HejPets-Windows-Preview'


def atomic_json(path, data):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False), encoding='utf-8')
    os.replace(temp, path)


def read_json(path, default):
    if not path.exists():
        return copy.deepcopy(default)
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (ValueError, OSError) as e:
        raise ValueError(f'无法读取 {path.name}，已保留原文件，请先备份后检查。') from e


def open_image(path):
    with Image.open(path) as im:
        im = ImageOps.exif_transpose(im).convert('RGBA')
        im.thumbnail((2560, 2560), Image.Resampling.LANCZOS)
        return im.copy()


def crop_box(im, rect):
    x, y, w, h = rect  # Persisted Mac rectangles have a bottom-left origin.
    left, top = clamp(x, 0, 1), clamp(1-y-h, 0, 1)
    right, bottom = clamp(x+w, 0, 1), clamp(1-y, 0, 1)
    box = (int(left*im.width), int(top*im.height), math.ceil(right*im.width), math.ceil(bottom*im.height))
    if box[2]-box[0] < 3 or box[3]-box[1] < 3:
        raise ValueError('选区太小，请重新选择。')
    return box


def crop(im, rect):
    return im.crop(crop_box(im, rect))


def face_rect(pet):
    return tuple(pet[k] for k in ('faceX', 'faceY', 'faceW', 'faceH'))


def clothing_rect(pet, lower=False):
    x, y, w, h = face_rect(pet)
    if lower:
        width = min(.70, max(.16, w*1.28))
        top = max(.06, y-h*.58)
        bottom = max(0, top-h*.54)
        return clamp(x+w/2-width/2, 0, 1-width), bottom, width, top-bottom
    if pet.get('clothingW') and pet.get('clothingH'):
        return tuple(pet[k] for k in ('clothingX', 'clothingY', 'clothingW', 'clothingH'))
    width, height = min(.62, max(.16, w*1.22)), min(.32, max(.10, h*.62))
    top = clamp(y+h*.04, height, 1)
    return clamp(x+w/2-width/2, 0, 1-width), top-height, width, height


def classifier(name):
    result = cv2.CascadeClassifier(str(Path(cv2.data.haarcascades) / name))
    if result.empty():
        raise RuntimeError('本地人脸检测模型缺失，请重新安装应用。')
    return result


def detect_raw(im):
    rgb = np.array(im.convert('RGB'))
    scale = min(1., 900/max(im.size))
    small = cv2.resize(rgb, None, fx=scale, fy=scale)
    gray = cv2.cvtColor(small, cv2.COLOR_RGB2GRAY)
    faces = classifier('haarcascade_frontalface_default.xml').detectMultiScale(gray, 1.1, 5, minSize=(28, 28))
    if len(faces) == 0:
        return None
    x, y, w, h = max(faces, key=lambda b: int(b[2])*int(b[3]))
    return (x/scale, y/scale, w/scale, h/scale)


def detect_face(im, fallback=(.20, .43, .60, .52)):
    raw = detect_raw(im)
    if raw is None:
        return fallback
    x, y, w, h = raw
    bw, bh = min(.94, w/im.width*1.58), min(.94, h/im.height*1.62)
    cx, cy = (x+w/2)/im.width, 1-(y+h/2)/im.height+h/im.height*.10
    return clamp(cx-bw/2, 0, 1-bw), clamp(cy-bh/2, 0, 1-bh), bw, bh


def features(im):
    raw = detect_raw(im)
    if raw is None:
        return None
    x, y, w, h = raw
    gray = cv2.cvtColor(np.array(im.convert('RGB')), cv2.COLOR_RGB2GRAY)
    x, y, w, h = [int(v) for v in (x, y, w, h)]
    eyes = classifier('haarcascade_eye_tree_eyeglasses.xml').detectMultiScale(gray[y:y+int(h*.62), x:x+w], 1.1, 4)
    centers = sorted([(x+ex+ew/2, y+ey+eh/2) for ex, ey, ew, eh in eyes], key=lambda p:p[0])
    left, right = ((x+w*.34, y+h*.38), (x+w*.66, y+h*.38))
    if len(centers) >= 2:
        left, right = centers[0], centers[-1]
    # Mouth position is estimated relative to the locally detected face.
    def norm(point):
        return [point[0]/im.width, 1-point[1]/im.height]
    return dict(leftEye=norm(left), rightEye=norm(right), mouth=norm((x+w*.5, y+h*.72)))


def outlined(im, mask):
    mask = mask.resize(im.size, Image.Resampling.LANCZOS).filter(ImageFilter.GaussianBlur(.65))
    alpha = Image.fromarray(np.minimum(np.array(mask), np.array(im.getchannel('A'))))
    edge = mask.filter(ImageFilter.MaxFilter(5))
    bg = Image.new('RGBA', im.size, (43, 38, 36, 0))
    bg.putalpha(edge.point(lambda v: int(v*.96)))
    subject = im.copy()
    subject.putalpha(alpha)
    return Image.alpha_composite(bg, subject)


def automatic_head(im, rect):
    x, y, w, h = rect
    region = (max(0, x-w*.05), y, min(1, x+w*1.05)-max(0,x-w*.05), min(1,y+h*1.04)-y)
    head = crop(im, region)
    if head.getchannel('A').getextrema()[0] < 200:
        return outlined(head, head.getchannel('A'))
    # Local GrabCut replaces Apple's unavailable Vision segmentation. No model download or upload.
    scale = min(1., 800/max(head.size))
    small = head.resize((max(8,int(head.width*scale)), max(8,int(head.height*scale))))
    rgb = np.array(small.convert('RGB'))
    sh, sw = rgb.shape[:2]
    mask = np.full((sh, sw), cv2.GC_PR_BGD, np.uint8)
    yy, xx = np.mgrid[:sh, :sw]
    ellipse = ((xx-sw*.5)/(sw*.46))**2 + ((yy-sh*.46)/(sh*.57))**2
    mask[ellipse < 1] = cv2.GC_PR_FGD
    mask[((xx-sw*.5)/(sw*.20))**2+((yy-sh*.48)/(sh*.25))**2 < 1] = cv2.GC_FGD
    mask[:2,:] = mask[-2:,:] = cv2.GC_BGD
    mask[:,:2] = mask[:,-2:] = cv2.GC_BGD
    try:
        cv2.grabCut(rgb, mask, None, np.zeros((1,65)), np.zeros((1,65)), 4, cv2.GC_INIT_WITH_MASK)
        result = np.where((mask==cv2.GC_FGD)|(mask==cv2.GC_PR_FGD),255,0).astype('uint8')
        if np.count_nonzero(result) < sw*sh*.05:
            raise ValueError('empty mask')
        alpha = Image.fromarray(result)
    except (cv2.error, ValueError):
        alpha = Image.fromarray(np.where(ellipse < 1,255,0).astype('uint8'))
    return outlined(head, alpha)


def paint_mask(size, strokes):
    scale = min(1., 1280/max(size))
    w, h = max(8,round(size[0]*scale)), max(8,round(size[1]*scale))
    mask = Image.new('L', (w,h))
    for stroke in strokes:
        points = [(round(clamp(p[0],0,1)*(w-1)), round(clamp(p[1],0,1)*(h-1))) for p in stroke['points']]
        if not points:
            continue
        radius = max(1, round(stroke['radius']*min(w,h)))
        color = 0 if stroke['erasing'] else 255
        draw = ImageDraw.Draw(mask)
        if stroke.get('fillsInterior') and not stroke['erasing'] and len(points)>2:
            boundary = Image.new('L',(w+2,h+2))
            bd = ImageDraw.Draw(boundary)
            shifted = [(x+1,y+1) for x,y in points]
            bd.line(shifted+[shifted[0]], fill=255, width=radius*2, joint='curve')
            ImageDraw.floodfill(boundary,(0,0),128)
            filled = np.where(np.array(boundary)[1:-1,1:-1]!=128,255,0).astype('uint8')
            mask = Image.fromarray(np.maximum(np.array(mask),filled))
        else:
            if len(points)>1:
                draw.line(points,fill=color,width=radius*2,joint='curve')
            for x,y in points:
                draw.ellipse((x-radius,y-radius,x+radius,y+radius), fill=color)
    return mask.resize(size,Image.Resampling.LANCZOS)


def painted(im, strokes, clothing=False):
    mask = paint_mask(im.size,strokes)
    box = mask.point(lambda v:255 if v>12 else 0).getbbox()
    if box is None or box[2]-box[0]<4 or box[3]-box[1]<4:
        raise ValueError('请先圈选或涂抹一块有效区域。')
    pad = max(2,round(min(im.size)*.006))
    box = (max(0,box[0]-pad),max(0,box[1]-pad),min(im.width,box[2]+pad),min(im.height,box[3]+pad))
    rect = (box[0]/im.width,1-box[3]/im.height,(box[2]-box[0])/im.width,(box[3]-box[1])/im.height)
    return (im if clothing else outlined(im,mask)).crop(box), rect


def sampled_color(im, start=0, end=1, fallback='#78A79F'):
    pixels = np.array(im.convert('RGBA').resize((60,60)))
    values = pixels[int(start*60):max(int(start*60)+1,int(end*60)),20:40].reshape(-1,4)/255.
    bright = (values[:,:3].max(axis=1)+values[:,:3].min(axis=1))/2
    values = values[(values[:,3]>.18)&(bright>.06)&(bright<.96),:3]
    if len(values)<3:
        return fallback
    weight=.65+values.max(axis=1)-values.min(axis=1)
    rgb=np.average(values,axis=0,weights=weight)
    lum=np.dot(rgb,[.299,.587,.114])
    if lum<.18: rgb=rgb*.84+.16
    if lum>.82:
        base=np.array([int(fallback[i:i+2],16) for i in (1,3,5)])/255
        rgb=rgb*.72+base*.28
    return '#'+''.join(f'{round(v*255):02X}' for v in rgb)


class Store:
    def __init__(self, root=None):
        self.root=Path(root) if root else data_root()
        self.images=self.root/'Images'
        self.images.mkdir(parents=True,exist_ok=True)
        self.pets=read_json(self.root/'pets.json',[])
        if not isinstance(self.pets,list): raise ValueError('pets.json 格式不正确，原文件已保留。')
        for pet in self.pets:
            for key in ('imageFilename','headFilename','clothingTextureFilename'):
                if pet.get(key): self.path(pet[key])
            rect=face_rect(pet)
            if not all(isinstance(v,(int,float)) and math.isfinite(v) for v in rect):
                raise ValueError('宠物裁切数据不正确，原文件已保留。')
        raw=read_json(self.root/'settings.json',{})
        if not isinstance(raw,dict): raise ValueError('settings.json 格式不正确，原文件已保留。')
        self.settings=copy.deepcopy(DEFAULTS)
        self.settings.update(raw)
        self.validate_settings()

    def validate_settings(self):
        s=self.settings
        for key,low,high in [('fixedMinutes',.1,120),('randomMinMinutes',.1,120),('randomMaxMinutes',.1,240)]:
            try: v=float(s[key])
            except (ValueError,TypeError): v=DEFAULTS[key]
            s[key]=clamp(v if math.isfinite(v) else DEFAULTS[key],low,high)
        s['randomMaxMinutes']=max(s['randomMinMinutes'],s['randomMaxMinutes'])
        if s['actionMode'] not in ACTIONS: s['actionMode']='mixed'
        if s['animationFPS'] not in (15,24,30,45,60): s['animationFPS']=30
        if s['mode'] not in ('fixed','random'): s['mode']='random'
        for k in ('messages','dragMessages'):
            if not isinstance(s[k],list): s[k]=DEFAULTS[k].copy()
            s[k]=[v.strip() for v in s[k] if isinstance(v,str) and v.strip()] or DEFAULTS[k].copy()

    def path(self, filename):
        if not filename or Path(filename).name!=filename or '\\' in filename or ':' in filename:
            raise ValueError('宠物文件名不正确。')
        result=(self.images/filename).resolve()
        if result.parent!=self.images.resolve(): raise ValueError('宠物文件路径不正确。')
        return result

    def save(self):
        atomic_json(self.root/'pets.json',self.pets)

    def save_settings(self):
        self.validate_settings()
        atomic_json(self.root/'settings.json',self.settings)

    def delay(self):
        s=self.settings
        return max(6,s['fixedMinutes']*60) if s['mode']=='fixed' else random.uniform(max(6,s['randomMinMinutes']*60),max(6,s['randomMaxMinutes']*60))

    def add(self, source):
        im=open_image(source)
        ident=str(uuid.uuid4()).upper()
        face=detect_face(im)
        head=automatic_head(im,face)
        pet=dict(id=ident,name=f'小宠物 {len(self.pets)+1}',imageFilename=f'{ident}.png',
                 headFilename=f'{ident}-head.png',headVersion=6,shirtHex=sampled_color(im,.48,.72),
                 pantsHex=sampled_color(im,.72,.92,'#475E64'),isVisible=True,faceFeatures=features(head))
        pet.update(zip(('faceX','faceY','faceW','faceH'),face))
        im.save(self.path(pet['imageFilename']))
        head.save(self.path(pet['headFilename']))
        self.pets.append(pet)
        try: self.save()
        except OSError:
            self.pets.remove(pet)
            for k in ('imageFilename','headFilename'): self.path(pet[k]).unlink(missing_ok=True)
            raise
        return pet

    def update_head(self, pet, mode='automatic', rect=None, strokes=None):
        im=open_image(self.path(pet['imageFilename']))
        updated=copy.deepcopy(pet)
        if mode=='freehand':
            head,_=painted(im,strokes)
            updated['headMaskStrokes']=strokes
        else:
            rect=detect_face(im,face_rect(pet)) if mode=='automatic' else rect
            head=automatic_head(im,rect)
            updated.update(zip(('faceX','faceY','faceW','faceH'),rect))
            updated['headMaskStrokes']=None
        updated['headVersion']=6
        updated['headFilename']=f"{pet['id']}-head.png"
        updated['faceFeatures']=features(head)
        self._commit_image(pet,updated,head,updated['headFilename'])

    def update_clothing(self,pet,strokes=None):
        im=open_image(self.path(pet['imageFilename']))
        updated=copy.deepcopy(pet)
        if strokes:
            texture,rect=painted(im,strokes,True)
            filename=f"{pet['id']}-clothing.png"
            updated['clothingTextureFilename']=filename
            updated['clothingMaskStrokes']=strokes
            updated.update(zip(('clothingX','clothingY','clothingW','clothingH'),rect))
            updated['shirtHex']=sampled_color(texture)
            self._commit_image(pet,updated,texture,filename)
        else:
            for key in ('clothingX','clothingY','clothingW','clothingH','clothingTextureFilename','clothingMaskStrokes'):
                updated[key]=None
            updated['shirtHex']=sampled_color(crop(im,clothing_rect(updated)))
            old=copy.deepcopy(pet)
            pet.clear();pet.update(updated)
            try: self.save()
            except OSError: pet.clear();pet.update(old);raise
            if old.get('clothingTextureFilename'):
                self.path(old['clothingTextureFilename']).unlink(missing_ok=True)

    def _commit_image(self,pet,updated,image,filename):
        # Unique output filename lets JSON replacement commit the edit atomically.
        filename=f"{Path(filename).stem}-{uuid.uuid4().hex[:8]}.png"
        key='clothingTextureFilename' if 'clothing' in filename else 'headFilename'
        updated[key]=filename
        image.save(self.path(filename))
        old=copy.deepcopy(pet)
        pet.clear();pet.update(updated)
        try: self.save()
        except OSError:
            pet.clear();pet.update(old);self.path(filename).unlink(missing_ok=True);raise
        if old.get(key) and old[key]!=filename: self.path(old[key]).unlink(missing_ok=True)

    def remove(self,pet):
        index=self.pets.index(pet)
        self.pets.pop(index)
        try: self.save()
        except OSError: self.pets.insert(index,pet);raise
        for k in ('imageFilename','headFilename','clothingTextureFilename'):
            if pet.get(k): self.path(pet[k]).unlink(missing_ok=True)
