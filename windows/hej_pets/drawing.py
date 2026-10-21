"""QPainter translation of the original Core Graphics character paths, in points."""
import math
from PIL.ImageQt import ImageQt
from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QFont, QImage, QLinearGradient, QPainter, QPainterPath, QPen
from .data import clamp, clothing_rect, crop, open_image

INK='#2C2927'

def color(value,alpha=None):
    c=QColor(value)
    if alpha is not None:c.setAlphaF(alpha)
    return c

def mixed(value,other,amount):
    a,b=QColor(value),QColor(other)
    return QColor.fromRgbF(a.redF()*(1-amount)+b.redF()*amount,a.greenF()*(1-amount)+b.greenF()*amount,a.blueF()*(1-amount)+b.blueF()*amount)

def qimage(im):return QImage(ImageQt(im)).copy()

def ellipse(p,x,y,w,h,fill,stroke=None,width=1):
    p.setBrush(color(fill) if isinstance(fill,str) else fill if fill else Qt.NoBrush)
    p.setPen(QPen(color(stroke),width) if stroke else Qt.NoPen)
    p.drawEllipse(QRectF(x,y,w,h))

def line(p,a,b,width,c):
    p.setPen(QPen(color(c) if isinstance(c,str) else c,width,Qt.SolidLine,Qt.RoundCap,Qt.RoundJoin))
    p.drawLine(QPointF(*a),QPointF(*b))

def path(coords):
    result=QPainterPath()
    for op,values in coords:
        if op=='M':result.moveTo(*values)
        elif op=='L':result.lineTo(*values)
        elif op=='C':result.cubicTo(*values)
        elif op=='Q':result.quadTo(*values)
        elif op=='Z':result.closeSubpath()
    return result

def fill_path(p,shape,c):p.fillPath(shape,color(c) if isinstance(c,str) else c)

def rounded(rect,r):
    shape=QPainterPath();shape.addRoundedRect(QRectF(*rect),r,r);return shape

def image_up(p,image,rect):
    # Painter uses the original Swift y-up coordinate system. Keep source images upright.
    x,y,w,h=rect
    p.save();p.translate(x,y+h);p.scale(1,-1);p.drawImage(QRectF(0,0,w,h),image);p.restore()

def texture(p,image,rect):
    x,y,w,h=rect
    ratio=max(w/image.width(),h/image.height())
    iw,ih=image.width()*ratio,image.height()*ratio
    image_up(p,image,(x+(w-iw)/2,y+(h-ih)/2,iw,ih))

def hand(p,point):
    x,y=point;ellipse(p,x-5,y-5,10,10,INK);ellipse(p,x-3.2,y-3.2,6.4,6.4,'#F6D0B3')

def shoe(p,point,direction):
    x,y=point;ellipse(p,x-7+direction*2,y-4,14,8,INK);ellipse(p,x-4+direction*3,y-1,7,3,'#F7F1E6')

def limb(p,origin,end,width,inner,c,is_hand=False,direction=-1):
    line(p,origin,end,width,INK);line(p,origin,end,inner,c)
    hand(p,end) if is_hand else shoe(p,end,direction)


class Character:
    def __init__(self,store,record):
        self.record=record
        im=open_image(store.path(record['imageFilename']))
        headfile=record.get('headFilename')
        self.head=qimage(open_image(store.path(headfile))) if headfile and store.path(headfile).exists() else qimage(crop(im,(record['faceX'],record['faceY'],record['faceW'],record['faceH'])))
        clothing=record.get('clothingTextureFilename')
        self.shirt=qimage(open_image(store.path(clothing))) if clothing and store.path(clothing).exists() else qimage(crop(im,clothing_rect(record)))
        try:self.pants=qimage(crop(im,clothing_rect(record,True)))
        except ValueError:self.pants=None

    def paint(self,p,m,tracking=True):
        p.setRenderHints(QPainter.Antialiasing|QPainter.SmoothPixmapTransform)
        p.save();p.translate(0,214);p.scale(1,-1)
        p.save()
        anchor={'bottom':(107,4),'right':(210,107),'top':(107,210),'left':(4,107)}[m.edge]
        p.translate(*anchor);p.rotate({'bottom':0,'right':90,'top':180,'left':-90}[m.edge]);p.scale(m.direction,1)
        wiggle=math.sin(m.phase*1.8) if m.state=='dragging' else 0
        if m.state=='dragging':p.rotate(wiggle*.11*180/math.pi)
        if m.state=='falling':p.rotate(math.sin(m.phase*1.3)*.18*180/math.pi)
        if m.state=='walking' and m.action in ('dance','hop'):self.upright(p,m,tracking)
        else:self.crawling(p,m,tracking,wiggle)
        p.restore()
        if m.bubble is not None:self.bubble(p,m)
        p.restore()

    def garment(self,p,shape,rect,pants=False):
        p.save();p.setClipPath(shape)
        im=self.pants if pants else self.shirt
        if im:texture(p,im,rect)
        else:p.fillRect(QRectF(*rect),color(self.record['pantsHex' if pants else 'shirtHex']))
        p.fillRect(QRectF(*rect),color(self.record['pantsHex' if pants else 'shirtHex'],.08 if pants else .10))
        if not pants:
            x,y,w,h=rect;g=QLinearGradient(x,y+h/2,x+w,y+h/2)
            g.setColorAt(0,color('#000000',.16));g.setColorAt(.52,color('#000000',0));g.setColorAt(1,color('#FFFFFF',.10))
            p.fillRect(QRectF(*rect),g)
        p.restore()

    def crawling(self,p,m,tracking,wiggle):
        phase,state=m.phase,m.state
        moving=(state=='walking' and m.action in ('dockCrawl','perimeter')) or state=='climbing'
        crawl=math.sin(phase) if moving else 0
        bob=abs(math.sin(phase))*2.8 if moving else 0
        shirt,pants=self.record['shirtHex'],self.record['pantsHex']
        p.save();p.scale(1,.30);ellipse(p,-57,3,119,18,color('#000000',.04 if state=='falling' else .13));p.restore()
        front,back,reach=max(0,crawl)*6,max(0,-crawl)*6,crawl*9
        fr=(-39+reach*.65,11+back);ff=(25-reach*.75,12+front)
        nr=(-26-reach*.72,9+front);nf=(43+reach*.82,9+back)
        if state in ('dragging','falling'):
            struggle=math.sin(phase*2.4)*11 if state=='dragging' else 0
            fr=(-47,42+struggle);ff=(43,47-struggle);nr=(-34,56-struggle);nf=(52,58+struggle)
        hip,shoulder=(-20,35+bob),(15,37+bob)
        limb(p,hip,fr,10,6.3,mixed(pants,'#FFFFFF',.08));limb(p,shoulder,ff,9,5.6,mixed(shirt,'#FFFFFF',.14),True)
        p.save();p.translate(0,bob);p.rotate(crawl*.025*180/math.pi if moving else 0)
        body=path([('M',(-35,37)),('C',(-36,49,-29,58,-17,60)),('C',(-3,62,23,61,29,53)),('C',(34,46,31,38,24,35)),('C',(6,29,-24,28,-35,37))])
        fill_path(p,body,INK)
        p.save();p.translate(0,1);p.scale(.91,.86);self.garment(p,body,(-39,27,76,40));p.restore()
        self.garment(p,rounded((-31,32,20,24),8),(-33,30,25,28),True)
        line(p,(-10,53),(-8,35),2.1,color('#FFF8E8',.72));line(p,(6,53),(14,50),1.8,color('#FFF8E8',.72));p.restore()
        collar=path([('M',(10,48+bob)),('C',(14,57+bob,19,62+bob*.6,24,63+bob*.45)),('C',(30,65+bob*.4,36,59+bob*.4,35,51+bob*.35)),('C',(29,45+bob,18,44+bob,10,48+bob))])
        fill_path(p,collar,INK);p.save();p.translate(0,1);p.scale(.88,.84);fill_path(p,collar,shirt);p.restore()
        limb(p,hip,nr,11,6.8,pants);limb(p,shoulder,nf,10,6.2,shirt,True)
        p.save();p.translate(26,57+bob*.42)
        p.rotate((-.10-crawl*.045 if moving else -.08+wiggle*.035)*180/math.pi)
        p.scale(1.05 if state=='falling' else .94 if state=='landed' else 1,.90 if state=='landed' else 1)
        self.draw_head(p,m,(-36,-10,72,84),tracking);p.restore()

    def upright(self,p,m,tracking):
        phase=m.phase;hop=m.action=='hop';beat=math.sin(phase*(.9 if hop else 1.25));lift=abs(math.sin(phase*.62)) if hop else 0
        shirt,pants=self.record['shirtHex'],self.record['pantsHex']
        p.save();p.scale(1-lift*.24,.28);ellipse(p,-38,4,76,18,color('#000000',.14-lift*.07));p.restore()
        p.save();p.translate(0 if hop else beat*3,3 if hop else abs(beat)*1.5);p.rotate(beat*(.025 if hop else .075)*180/math.pi)
        kl=lift*13 if hop else 0
        lf=(-16-(beat*5 if hop else 0),9+kl);rf=(16+(beat*5 if hop else 0),9+kl*.72)
        limb(p,(-10,38),lf,10,6,pants);limb(p,(10,38),rf,10,6,mixed(pants,'#FFFFFF',.06),direction=1)
        fill_path(p,rounded((-24,35,48,52),17),INK)
        self.garment(p,rounded((-21,38,42,47),15),(-23,36,46,51))
        lh=(-34,98+beat*7) if hop else (-42,76+beat*18)
        rh=(34,98-beat*7) if hop else (42,76-beat*18)
        limb(p,(-19,73),lh,9,5.5,shirt,True);limb(p,(19,73),rh,9,5.5,shirt,True)
        p.save();p.translate(0,112);p.rotate(-beat*.055*180/math.pi);self.draw_head(p,m,(-37,-28,74,84),tracking);p.restore();p.restore()

    def draw_head(self,p,m,rect,tracking):
        x,y,w,h=rect
        scale=min(w/self.head.width(),h/self.head.height())
        w,h=self.head.width()*scale,self.head.height()*scale
        fitted=(-w/2,y,w,h);image_up(p,self.head,fitted)
        self.expression(p,m,fitted,tracking)

    def expression(self,p,m,rect,tracking):
        x,y,w,h=rect
        f=self.record.get('faceFeatures') if tracking else None
        def pos(key,default):
            value=(f or {}).get(key,default)
            # Swift CGPoint JSON is an array; accept dictionary exports as well.
            if isinstance(value,dict):value=(value['x'],value['y'])
            return x+clamp(value[0],0,1)*w,y+clamp(value[1],0,1)*h
        le,re,mo=pos('leftEye',(.34,.62)),pos('rightEye',(.66,.62)),pos('mouth',(.5,.31))
        r=clamp(max(4,abs(re[0]-le[0]))*.18,2.5,6)
        def closed(center):
            cx,cy=center
            shape=path([('M',(cx-r*1.25,cy)),('Q',(cx,cy-r,cx+r*1.25,cy))])
            p.setBrush(Qt.NoBrush);p.setPen(QPen(color(INK),2,Qt.SolidLine,Qt.RoundCap));p.drawPath(shape)
        def wide(center):
            cx,cy=center;ellipse(p,cx-r,cy-r*1.15,r*2,r*2.3,color('#FFFFFF',.88),INK,1.4)
            ellipse(p,cx-r*.43,cy-r*.58,r*.86,r*1.16,INK)
        if m.state=='dragging':
            line(p,(le[0]-r,le[1]+r*1.8),(le[0]+r,le[1]+r*1.25),2.1,INK)
            line(p,(re[0]-r,re[1]+r*1.25),(re[0]+r,re[1]+r*1.8),2.1,INK)
            ellipse(p,x+w-7,y+h-13,6,10,'#75C9E8')
        elif m.state=='falling':
            wide(le);wide(re);ellipse(p,mo[0]-4,mo[1]-5,8,10,None,INK,2)
        elif m.state=='landed':
            for cx,cy in (le,re):
                line(p,(cx-3,cy-3),(cx+3,cy+3),1.8,INK);line(p,(cx-3,cy+3),(cx+3,cy-3),1.8,INK)
            for i in range(3):
                a=m.phase+i*2.09;ellipse(p,x+w/2+math.cos(a)*w*.32-2.2,y+h+math.sin(a)*3-2.2,4.4,4.4,'#F29D8D' if i==0 else '#FFCF5A')
        elif m.state=='reacting':
            closed(le);closed(re)
            ellipse(p,le[0]-r*1.8,mo[1],r*1.7,r*.8,color('#F48E91',.58));ellipse(p,re[0]+r*.1,mo[1],r*1.7,r*.8,color('#F48E91',.58))
            p.save();p.translate(x+w+3,y+h-2+math.sin(m.phase)*2)
            fill_path(p,path([('M',(0,-5)),('C',(-4,-1,-9,-1,-8,2)),('C',(-8,7,-3,9,0,9)),('C',(3,9,8,7,8,2)),('C',(9,-1,4,-1,0,-5))]),'#F26C74');p.restore()
        elif m.state=='climbing':
            for xx,sign in ((x-5,1),(x+w+5,-1)):
                line(p,(xx,y+h/2),(xx+sign*7,y+h/2+4),2.5,'#F29D8D');line(p,(xx+sign*7,y+h/2+4),(xx+sign*3,y+h/2+10),2.5,'#F29D8D')
        elif m.action=='dance':
            closed(le);closed(re);shape=path([('M',(mo[0]-4,mo[1])),('Q',(mo[0],mo[1]-4,mo[0]+4,mo[1]))]);p.setPen(QPen(color(INK),1.8));p.drawPath(shape)
        elif m.action=='hop':wide(le);wide(re)
        if m.bubble is not None:
            mh=max(5,h*(.10+abs(math.sin(m.phase*1.7))*.045));mw=max(7,w*.18)
            ellipse(p,mo[0]-mw/2,mo[1]-mh/2,mw,mh,color(INK,.92));ellipse(p,mo[0]-mw*.31,mo[1]-mh*.22,mw*.62,max(2,mh*.34),'#F08B91')

    def bubble(self,p,m):
        x=clamp(107-86 if m.direction>0 else 107-46,5,77)
        shape=rounded((x,166,132,38),13)
        fill_path(p,shape,color('#FFFDF7',.97));p.setPen(QPen(color('#3C3935',.72),1.5));p.setBrush(Qt.NoBrush);p.drawPath(shape)
        tip=107+m.direction*27;base=clamp(tip-m.direction*7,x+18,x+114)
        fill_path(p,path([('M',(base-7,167)),('L',(tip,154)),('L',(base+7,167)),('Z',())]),'#FFFDF7')
        p.save();p.translate(x+10,194);p.scale(1,-1);p.setPen(color('#393632'));font=QFont();font.setPixelSize(13);font.setWeight(QFont.Medium);p.setFont(font)
        text=p.fontMetrics().elidedText(m.bubble,Qt.ElideRight,112)
        p.drawText(QRectF(0,0,112,20),Qt.AlignCenter,text);p.restore()
