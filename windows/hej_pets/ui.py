from __future__ import annotations
import copy
import math
import time
from pathlib import Path

from PIL import Image
from PySide6.QtCore import QPointF, QRectF, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QFont, QIcon, QLinearGradient, QPainter, QPainterPath, QPen, QPixmap
from PySide6.QtWidgets import (QAbstractButton, QApplication, QCheckBox, QComboBox, QDialog, QDoubleSpinBox,
    QFrame, QHBoxLayout, QLabel, QMenu, QMessageBox, QPushButton, QScrollArea, QSlider,
    QSystemTrayIcon, QTextEdit, QVBoxLayout, QWidget)
from .data import ACTIONS, clamp, face_rect, open_image, paint_mask
from .drawing import Character, color, qimage
from .motion import Motion
from .native import configure_overlay

STYLE='''
QWidget { color: #393632; font-family: "Microsoft YaHei UI", "PingFang SC", sans-serif; font-size: 13px; }
QDialog { background: #F7F3EA; }
QPushButton { background: #DDEBE6; color: #355F57; border: 1px solid #C6DDD5; border-radius: 9px; font-size: 13px; font-weight: 600; padding: 4px; }
QPushButton:hover { background: #D1E3DB; } QPushButton:pressed { background: #BCD6CA; }
QPushButton:focus { border: 2px solid #5F958A; }
QComboBox,QDoubleSpinBox,QTextEdit { background: #FFFDFA; border: 1px solid #D8D3C9; border-radius: 5px; padding: 4px; }
QTextEdit { font-size: 13px; } QLabel { background: transparent; }
QScrollArea { border: none; background: transparent; }
QScrollBar:vertical { width: 8px; background: transparent; } QScrollBar::handle:vertical { background: #C9D4CC; border-radius: 4px; min-height: 20px; }
QScrollBar::add-line:vertical,QScrollBar::sub-line:vertical { height: 0; }
QCheckBox::indicator { width: 17px; height: 17px; }
'''


def label(parent,text,rect,size=13,bold=False,tint='#393632'):
    item=QLabel(text,parent);item.setGeometry(*rect)
    item.setStyleSheet(f'font-size:{size}px;font-weight:{600 if bold else 400};color:{tint};')
    return item


def button(parent,text,rect,callback,tone='green'):
    item=QPushButton(text,parent);item.setGeometry(*rect);item.clicked.connect(callback)
    if tone=='white':item.setStyleSheet('QPushButton{background:#FFFDFA;color:#655F57;border-color:#D8D3C9;}QPushButton:hover{background:#EFEAE1;}')
    elif tone=='red':item.setStyleSheet('QPushButton{background:#F7E6E1;color:#8A4E49;border-color:#E8CCC4;}QPushButton:hover{background:#EFD7CF;}')
    elif tone=='blue':item.setStyleSheet('QPushButton{background:#E8EEF4;color:#4E6475;border-color:#D2DDE5;}QPushButton:hover{background:#D7E3EB;}')
    elif tone=='brown':item.setStyleSheet('QPushButton{background:#F3EDE5;color:#745E48;border-color:#E2D4C4;}QPushButton:hover{background:#E7DCCD;}')
    return item


class PetWindow(QWidget):
    def __init__(self,store,record):
        super().__init__(None,Qt.Tool|Qt.FramelessWindowHint|Qt.WindowStaysOnTopHint|Qt.WindowDoesNotAcceptFocus)
        self.setAttribute(Qt.WA_TranslucentBackground);self.setAttribute(Qt.WA_ShowWithoutActivating)
        self.setFixedSize(214,214);self.setWindowTitle(record['name']);self.setCursor(Qt.OpenHandCursor)
        self.store=store;self.record=record;self.character=Character(store,record)
        self.active_screen=QApplication.primaryScreen()
        left,right,bottom,top=self.bounds()
        seed=int(record['id'].replace('-','')[:8],16)%1000/1000
        self.motion=Motion(left+16+seed*max(40,right-left-32),bottom,store.settings,store.delay)
        self.motion.direction=-1 if seed>.5 else 1
        self.last_drag=time.monotonic();self.place()

    def showEvent(self,event):
        super().showEvent(event);configure_overlay(self)

    def bounds(self):
        screen=self.active_screen or QApplication.primaryScreen()
        g,a=screen.geometry(),screen.availableGeometry()
        floor=-a.y()-a.height()-9 if g.bottom()-a.bottom()>8 else -g.y()-g.height()+4
        left,right=g.x()+4,max(g.x()+4,g.x()+g.width()-218)
        return left,right,floor,max(floor,-g.y()-218)

    def ensure_screen(self):
        screen=QApplication.screenAt(self.frameGeometry().center())
        if screen:self.active_screen=screen
        elif self.active_screen not in QApplication.screens():
            self.active_screen=QApplication.primaryScreen()
            l,r,b,t=self.bounds();self.motion.x=clamp(self.motion.x,l,r);self.motion.y=b
        # Work-area changes (taskbar, DPI, unplugging monitor) clamp on the next frame.
        if self.motion.state=='walking':
            l,r,b,t=self.bounds();self.motion.x=clamp(self.motion.x,l,r)
            if self.motion.edge=='top':self.motion.y=t
            elif self.motion.edge in ('left','right'):self.motion.y=clamp(self.motion.y,b,t)

    def place(self):self.move(math.floor(self.motion.x),math.floor(-self.motion.y-214))
    def tick(self,dt,paused=False):
        self.ensure_screen();self.motion.tick(dt,self.bounds(),paused);self.place();self.update()
    def paintEvent(self,event):
        p=QPainter(self);self.character.paint(p,self.motion,self.store.settings['faceTrackingEnabled']);p.end()
    def mousePressEvent(self,event):
        if event.button()==Qt.LeftButton:
            pos=event.globalPosition();self.motion.start_drag(pos.x(),-pos.y());self.last_drag=time.monotonic();self.setCursor(Qt.ClosedHandCursor);self.update()
    def mouseMoveEvent(self,event):
        if self.motion.state=='dragging':
            pos=event.globalPosition();now=time.monotonic();self.motion.drag(pos.x(),-pos.y(),now-self.last_drag);self.last_drag=now
            screen=QApplication.screenAt(pos.toPoint())
            if screen:self.active_screen=screen
            self.place();self.update()
    def mouseReleaseEvent(self,event):
        if event.button()==Qt.LeftButton:self.motion.end_drag();self.setCursor(Qt.OpenHandCursor);self.update()


class PhotoCanvas(QWidget):
    def __init__(self,image,record,clothing=False):
        super().__init__();self.setMinimumSize(400,300);self.im=image;self.photo=qimage(image)
        self.clothing=clothing;self.mode='outline';self.radius=.018
        self.strokes=copy.deepcopy(record.get('clothingMaskStrokes' if clothing else 'headMaskStrokes') or [])
        self.rect=QRectF(record['faceX'],1-record['faceY']-record['faceH'],record['faceW'],record['faceH'])
        self.features=copy.deepcopy(record.get('faceFeatures') or {'leftEye':[.34,.62],'rightEye':[.66,.62],'mouth':[.5,.31]})
        self.current=None;self.drag_mode=None;self.mask=None;self.mask_dirty=True
        self.setMouseTracking(True)

    def image_rect(self):
        scale=min((self.width()-24)/self.im.width,(self.height()-24)/self.im.height)
        w,h=self.im.width*scale,self.im.height*scale
        return QRectF((self.width()-w)/2,(self.height()-h)/2,w,h)

    def norm(self,pos):
        r=self.image_rect();return QPointF(clamp((pos.x()-r.x())/r.width(),0,1),clamp((pos.y()-r.y())/r.height(),0,1))

    def selection(self):
        r=self.image_rect();s=self.rect;return QRectF(r.x()+s.x()*r.width(),r.y()+s.y()*r.height(),s.width()*r.width(),s.height()*r.height())

    def paintEvent(self,event):
        p=QPainter(self);p.setRenderHints(QPainter.Antialiasing|QPainter.SmoothPixmapTransform)
        p.fillRect(self.rect_canvas(),color('#E8E5DD'));r=self.image_rect()
        p.drawImage(r,self.photo)
        if self.mode=='rectangle':
            selected=self.selection();shade=QPainterPath();shade.addRect(r);shade.addRect(selected);shade.setFillRule(Qt.OddEvenFill)
            p.fillPath(shade,color('#000000',.40));p.setPen(QPen(color('#5F958A'),2));p.setBrush(Qt.NoBrush);p.drawRect(selected)
            for point in (selected.topLeft(),selected.topRight(),selected.bottomLeft(),selected.bottomRight()):
                p.fillRect(QRectF(point.x()-4,point.y()-4,8,8),color('#FFFDFA'))
        elif self.mode=='features':
            for key,title in [('leftEye','左眼'),('rightEye','右眼'),('mouth','嘴')]:
                value=self.features[key];x,y=(value['x'],value['y']) if isinstance(value,dict) else value
                pt=QPointF(r.x()+x*r.width(),r.y()+(1-y)*r.height());p.setPen(QPen(color('#F26C74'),2));p.setBrush(color('#FFFDF7'));p.drawEllipse(pt,5,5);p.drawText(pt+QPointF(8,-8),title)
        elif self.strokes:
            if self.mask_dirty:
                mask=paint_mask(self.im.size,self.strokes)
                overlay=Image.new('RGBA',self.im.size,(72,155,128,0));overlay.putalpha(mask.point(lambda v:int(v*.38)))
                self.mask=qimage(overlay);self.mask_dirty=False
            p.drawImage(r,self.mask)
        p.end()

    def rect_canvas(self):return QRectF(0,0,self.width(),self.height())

    def mousePressEvent(self,event):
        if event.button()!=Qt.LeftButton or not self.image_rect().contains(event.position()):return
        self.start=self.norm(event.position());self.original=QRectF(self.rect)
        if self.mode=='rectangle':
            sel=self.selection();corners=[sel.topLeft(),sel.topRight(),sel.bottomLeft(),sel.bottomRight()]
            hits=[i for i,pt in enumerate(corners) if (pt-event.position()).manhattanLength()<16]
            self.drag_mode=hits[0] if hits else 'move' if sel.contains(event.position()) else 'new'
            if self.drag_mode=='new':self.rect=QRectF(self.start,self.start)
        elif self.mode=='features':
            r=self.image_rect();pos=self.norm(event.position())
            def dist(key):
                v=self.features[key];x,y=(v['x'],v['y']) if isinstance(v,dict) else v
                return math.hypot((x-pos.x())*r.width(),(1-y-pos.y())*r.height())
            self.drag_mode=min(self.features,key=dist)
            self.features[self.drag_mode]=[pos.x(),1-pos.y()]
        else:
            self.current={'points':[[self.start.x(),self.start.y()]],'radius':self.radius,'erasing':self.mode=='erase','fillsInterior':self.mode=='outline'}
            self.strokes.append(self.current);self.mask_dirty=True
        self.update()

    def mouseMoveEvent(self,event):
        if not event.buttons()&Qt.LeftButton:return
        pt=self.norm(event.position())
        if self.mode=='rectangle' and self.drag_mode is not None:
            if self.drag_mode=='new':self.rect=QRectF(self.start,pt).normalized()
            elif self.drag_mode=='move':
                self.rect=QRectF(clamp(self.original.x()+pt.x()-self.start.x(),0,1-self.original.width()),clamp(self.original.y()+pt.y()-self.start.y(),0,1-self.original.height()),self.original.width(),self.original.height())
            else:
                opposite=[self.original.bottomRight(),self.original.bottomLeft(),self.original.topRight(),self.original.topLeft()][self.drag_mode]
                self.rect=QRectF(opposite,pt).normalized()
        elif self.mode=='features' and self.drag_mode:self.features[self.drag_mode]=[pt.x(),1-pt.y()]
        elif self.current:
            self.current['points'].append([pt.x(),pt.y()]);self.mask_dirty=True
        self.update()

    def mouseReleaseEvent(self,event):self.current=None;self.drag_mode=None
    def undo(self):
        if self.strokes:self.strokes.pop();self.mask_dirty=True;self.update()


class CropDialog(QDialog):
    def __init__(self,parent,store,pet,clothing=False):
        super().__init__(parent);self.store,self.pet,self.clothing=store,pet,clothing
        self.setWindowTitle('衣服材质' if clothing else '调整头部裁切');self.resize(760,700)
        self.canvas=PhotoCanvas(open_image(store.path(pet['imageFilename'])),pet,clothing)
        layout=QVBoxLayout(self);layout.setContentsMargins(20,20,20,24);layout.addWidget(self.canvas,1)
        self.hint=QLabel('沿轮廓画一圈，内部自动填满；也可涂抹补选、擦除修边。');layout.addWidget(self.hint)
        row=QHBoxLayout();layout.addLayout(row)
        self.mode=QComboBox();self.modes=['outline','brush','erase']+([] if clothing else ['rectangle'])
        self.mode.addItems(['自由圈选','涂抹补选','橡皮擦']+([] if clothing else ['矩形范围']))
        self.mode.currentIndexChanged.connect(self.change_mode);row.addWidget(self.mode)
        self.slider=QSlider(Qt.Horizontal);self.slider.setRange(4,80);self.slider.setValue(26);self.slider.setFixedWidth(90)
        self.slider.valueChanged.connect(self.brush);row.addWidget(self.slider)
        undo=QPushButton('撤销');undo.clicked.connect(self.canvas.undo);row.addWidget(undo)
        auto=QPushButton('自动检测' if clothing else '自动识别');auto.clicked.connect(self.auto);row.addWidget(auto)
        row.addStretch()
        cancel=QPushButton('取消');cancel.clicked.connect(self.reject);row.addWidget(cancel)
        self.apply=QPushButton('使用涂抹衣料' if clothing else '使用选区');self.apply.clicked.connect(self.commit);row.addWidget(self.apply)
        self.brush(26)

    def brush(self,value):
        r=self.canvas.image_rect();self.canvas.radius=value/max(1,min(r.width(),r.height()))/2
    def change_mode(self,index):self.canvas.mode=self.modes[index];self.canvas.update()
    def perform(self,callback):
        QApplication.setOverrideCursor(Qt.WaitCursor)
        try:callback()
        except Exception as e:QMessageBox.warning(self,'未能应用选区',str(e));return False
        finally:QApplication.restoreOverrideCursor()
        self.accept();return True
    def auto(self):
        self.perform(lambda:self.store.update_clothing(self.pet) if self.clothing else self.store.update_head(self.pet))
    def commit(self):
        if self.clothing:
            if not self.canvas.strokes:
                QMessageBox.information(self,'尚未选择衣料','先沿衣料圈一圈或涂抹一块区域。');return
            self.perform(lambda:self.store.update_clothing(self.pet,self.canvas.strokes))
        elif self.canvas.mode=='rectangle':
            r=self.canvas.rect
            self.perform(lambda:self.store.update_head(self.pet,'rectangle',(r.x(),1-r.y()-r.height(),r.width(),r.height())))
        else:self.perform(lambda:self.store.update_head(self.pet,'freehand',strokes=self.canvas.strokes))


class SettingsDialog(QDialog):
    def __init__(self,parent,store):
        super().__init__(parent);self.store=store;self.setWindowTitle('互动设置');self.setFixedSize(560,680);s=store.settings
        label(self,'动作模式',(28,20,100,25),14,True)
        self.action=QComboBox(self);self.action.addItems(list(ACTIONS.values()));self.action.setCurrentIndex(list(ACTIONS).index(s['actionMode']));self.action.setGeometry(128,18,180,30)
        self.face=QCheckBox('自动检测五官，把表情贴到真实眼睛和嘴巴位置',self);self.face.setGeometry(28,58,500,25);self.face.setChecked(s['faceTrackingEnabled'])
        label(self,'气泡出现时间',(28,92,150,25),14,True)
        self.mode=QComboBox(self);self.mode.addItems(['固定间隔','随机时间']);self.mode.setCurrentIndex(0 if s['mode']=='fixed' else 1);self.mode.setGeometry(28,126,120,30)
        self.fields=[]
        for title,key,x,high in [('固定（分钟）','fixedMinutes',168,120),('随机最短','randomMinMinutes',282,120),('随机最长','randomMaxMinutes',386,240)]:
            label(self,title,(x,114,105,20),12,tint='#746E65');field=QDoubleSpinBox(self);field.setRange(.1,high);field.setDecimals(1);field.setValue(s[key]);field.setGeometry(x,140,92,28);self.fields.append((key,field))
        label(self,'动画帧数',(28,188,100,25),14,True)
        self.fps=QComboBox(self);self.fps.addItems([f'{v} FPS' for v in (15,24,30,45,60)]);self.fps.setCurrentText(f"{s['animationFPS']} FPS");self.fps.setGeometry(128,184,110,30)
        label(self,'30 FPS 较轻量；60 FPS 更顺滑但更耗电。',(248,188,300,22),11,tint='#746E65')
        label(self,'平时说的话（每行一句）',(28,232,260,25),14,True)
        self.messages=QTextEdit(self);self.messages.setAcceptRichText(False);self.messages.setPlainText('\n'.join(s['messages']));self.messages.setGeometry(28,260,504,170)
        label(self,'被拽起来时说的话（每行一句）',(28,450,350,25),14,True)
        self.drag_messages=QTextEdit(self);self.drag_messages.setAcceptRichText(False);self.drag_messages.setPlainText('\n'.join(s['dragMessages']));self.drag_messages.setGeometry(28,478,504,122)
        button(self,'取消',(350,617,80,36),self.reject,'white');button(self,'保存设置',(442,617,90,36),self.save)
    def save(self):
        before=copy.deepcopy(self.store.settings);s=self.store.settings
        s['actionMode']=list(ACTIONS)[self.action.currentIndex()];s['faceTrackingEnabled']=self.face.isChecked();s['mode']='fixed' if self.mode.currentIndex()==0 else 'random'
        for key,field in self.fields:s[key]=field.value()
        s['animationFPS']=int(self.fps.currentText().split()[0]);s['messages']=self.messages.toPlainText().splitlines();s['dragMessages']=self.drag_messages.toPlainText().splitlines()
        try:self.store.save_settings()
        except OSError as e:s.clear();s.update(before);QMessageBox.warning(self,'无法保存设置',str(e));return
        self.accept()


class DropZone(QFrame):
    files=Signal(list)
    def __init__(self,parent):
        super().__init__(parent);self.hover=False;self.setAcceptDrops(True)
    def dragEnterEvent(self,event):
        if event.mimeData().hasUrls():self.hover=True;self.update();event.acceptProposedAction()
    def dragLeaveEvent(self,event):self.hover=False;self.update()
    def dropEvent(self,event):
        self.hover=False;self.update();paths=[u.toLocalFile() for u in event.mimeData().urls() if u.isLocalFile()]
        if paths:self.files.emit(paths[:8]);event.acceptProposedAction()
    def paintEvent(self,event):
        p=QPainter(self);p.setRenderHint(QPainter.Antialiasing);p.setBrush(color('#E4F0EC') if self.hover else color('#FFFFFF',.72))
        pen=QPen(color('#5F958A' if self.hover else '#BBB4A8'),2.2 if self.hover else 1.4,Qt.DashLine);pen.setDashPattern([6,5]);p.setPen(pen)
        p.drawRoundedRect(QRectF(1.5,1.5,self.width()-3,self.height()-3),16,16)
        p.setPen(QPen(color('#5F958A'),2));p.setBrush(Qt.NoBrush);p.drawRoundedRect(QRectF(37,32,39,31),5,5);p.drawEllipse(QPointF(47,41),3,3)
        p.drawLine(39,58,51,46);p.drawLine(51,46,59,54);p.drawLine(59,54,66,48)
        p.setPen(QPen(color('#5F958A'),2));p.drawLine(72,27,72,41);p.drawLine(65,34,79,34);p.end()


class VisibilitySwitch(QAbstractButton):
    def __init__(self,parent):
        super().__init__(parent);self.setCheckable(True);self.setAccessibleName('在桌面显示');self.setCursor(Qt.PointingHandCursor)
    def paintEvent(self,event):
        p=QPainter(self);p.setRenderHint(QPainter.Antialiasing)
        p.setPen(QPen(color('#5F958A' if self.isChecked() else '#C4C6C1'),1));p.setBrush(color('#75A997' if self.isChecked() else '#D9DDD7'))
        p.drawRoundedRect(QRectF(1,2,36,21),10.5,10.5)
        p.setPen(Qt.NoPen);p.setBrush(color('#FFFFFF'));p.drawEllipse(QRectF(18 if self.isChecked() else 3,4,17,17))
        if self.hasFocus():p.setPen(QPen(color('#355F57'),1,Qt.DotLine));p.setBrush(Qt.NoBrush);p.drawRoundedRect(QRectF(0,0,39,25),12,12)
        p.end()


class DeleteButton(QAbstractButton):
    def __init__(self,parent):
        super().__init__(parent);self.setToolTip('删除宠物');self.setAccessibleName('删除宠物');self.setCursor(Qt.PointingHandCursor)
    def paintEvent(self,event):
        p=QPainter(self);p.setRenderHint(QPainter.Antialiasing);p.setPen(QPen(color('#A55B58'),1.6,Qt.SolidLine,Qt.RoundCap,Qt.RoundJoin));p.setBrush(Qt.NoBrush)
        p.drawLine(9,10,23,10);p.drawLine(13,7,19,7);p.drawLine(11,12,12,24);p.drawLine(12,24,20,24);p.drawLine(20,24,21,12);p.drawLine(15,13,15,21);p.drawLine(18,13,18,21)
        if self.hasFocus():p.drawRoundedRect(QRectF(1,1,29,29),6,6)
        p.end()


class Card(QFrame):
    def __init__(self,parent,store,pet,on_toggle,on_delete,on_edit):
        super().__init__(parent);self.setFixedHeight(76);self.setMinimumWidth(484)
        self.setStyleSheet('Card {background:rgba(255,255,255,209);border:1px solid #E8E2D7;border-radius:15px;}')
        preview=QLabel(self);preview.setGeometry(14,10,56,56)
        try:
            im=qimage(open_image(store.path(pet['imageFilename'])));pix=QPixmap(56,56);pix.fill(Qt.transparent);p=QPainter(pix);p.setRenderHints(QPainter.Antialiasing|QPainter.SmoothPixmapTransform);clip=QPainterPath();clip.addRoundedRect(QRectF(0,0,56,56),16,16);p.setClipPath(clip);p.drawImage(QRectF(0,0,56,56),im);p.end();preview.setPixmap(pix)
        except (OSError,ValueError):preview.setText('照片缺失')
        label(self,pet['name'],(78,25,125,25),14,True)
        button(self,'调整裁切',(212,22,82,31),lambda:on_edit(pet,False))
        button(self,'衣服材质',(300,22,88,31),lambda:on_edit(pet,True),'brown')
        self.toggle=VisibilitySwitch(self);self.toggle.setGeometry(405,25,40,26);self.toggle.setToolTip('在桌面显示');self.toggle.setChecked(pet.get('isVisible',True));self.toggle.toggled.connect(lambda value:on_toggle(pet,value))
        delete=DeleteButton(self);delete.setGeometry(450,22,32,31);delete.clicked.connect(lambda:on_delete(pet))


class Manager(QWidget):
    def __init__(self,store,icon):
        super().__init__();self.store=store;self.windows={};self.paused=False
        self.setWindowTitle('Hej’s Pets');self.setWindowIcon(icon);self.setMinimumSize(560,610);self.resize(560,610)
        self.title=label(self,'Hej’s Pets',(30,38,300,40),31,True,'#292725')
        self.subtitle=label(self,'把喜欢的人，放到任务栏上陪你。',(31,78,350,22),14,tint='#6F6A62')
        self.maker=label(self,'HEJ 制作',(449,49,80,22),11,True,'#426C64');self.maker.setAlignment(Qt.AlignCenter);self.maker.setStyleSheet('background:#DDEBE6;border-radius:10px;color:#426C64;font-size:11px;font-weight:700;')
        self.drop=DropZone(self);self.drop.setGeometry(30,118,500,105);self.drop.files.connect(self.add_files)
        label(self.drop,'放一张照片进来',(93,26,210,22),15,True,'#302E2B')
        label(self.drop,'拖到这里，或选择照片 · JPG / PNG / HEIC',(93,51,300,20),11,tint='#827B71')
        self.choose=button(self.drop,'选择照片',(393,34,88,34),self.choose_photos)
        self.count=label(self,'我的宠物',(31,243,300,22),13,True,'#524E48')
        self.scroll=QScrollArea(self);self.scroll.setGeometry(30,270,500,260);self.scroll.setWidgetResizable(True);self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.list=QWidget();self.list.setStyleSheet('background:transparent;');self.cards=QVBoxLayout(self.list);self.cards.setContentsMargins(0,1,0,8);self.cards.setSpacing(10);self.cards.setAlignment(Qt.AlignTop);self.scroll.setWidget(self.list)
        self.settings_button=button(self,'互动设置',(220,558,100,30),self.settings_dialog,'blue')
        self.quit_button=button(self,'退出应用',(330,558,90,30),QApplication.instance().quit,'red')
        self.pause_button=button(self,'暂停爬行',(430,558,100,30),self.toggle_pause,'white')
        self.tray=QSystemTrayIcon(icon,self);self.tray.setToolTip('Hej’s Pets');self.tray.activated.connect(self.tray_open)
        if QSystemTrayIcon.isSystemTrayAvailable():self.tray.show()
        self.timer=QTimer(self);self.timer.setTimerType(Qt.PreciseTimer);self.timer.timeout.connect(self.tick);self.last_tick=time.monotonic()
        self.timer.start(round(1000/store.settings['animationFPS']))
        self.reload()
        for pet in store.pets:
            if pet.get('isVisible',True):self.spawn(pet)
        self.menu()
        QApplication.instance().aboutToQuit.connect(self.shutdown)

    def paintEvent(self,event):
        p=QPainter(self);p.setRenderHint(QPainter.Antialiasing);g=QLinearGradient(0,0,self.width(),self.height());g.setColorAt(0,color('#F7F3EA'));g.setColorAt(1,color('#EEF3EF'));p.fillRect(self.rect(),g);p.setBrush(color('#FFFFFF',.30));p.setPen(Qt.NoPen);p.drawEllipse(QRectF(self.width()-180,-90,330,330));p.end()
    def resizeEvent(self,event):
        if not hasattr(self,'drop'):return
        w,h=self.width(),self.height();self.maker.move(w-111,49);self.drop.resize(w-60,105);self.choose.move(w-167,34);self.scroll.setGeometry(30,270,w-60,h-350)
        self.settings_button.move(w-340,h-52);self.quit_button.move(w-230,h-52);self.pause_button.move(w-130,h-52)
    def reload(self):
        while self.cards.count():
            item=self.cards.takeAt(0)
            if item.widget():item.widget().deleteLater()
        count=len(self.store.pets);self.count.setText(f'我的宠物  ·  {count} 只' if count else '我的宠物')
        if not count:
            empty=QLabel('还没有小宠物，先放一张喜欢的照片吧。');empty.setAlignment(Qt.AlignCenter);empty.setFixedHeight(64);empty.setStyleSheet('color:#918A80;font-size:13px;');self.cards.addWidget(empty)
        for pet in self.store.pets:self.cards.addWidget(Card(self.list,self.store,pet,self.toggle,self.delete,self.edit))
        self.menu()
    def choose_photos(self):
        from PySide6.QtWidgets import QFileDialog
        paths,_=QFileDialog.getOpenFileNames(self,'选择要变成桌宠的照片','','照片 (*.jpg *.jpeg *.png *.heic *.heif *.webp *.tif *.tiff);;全部文件 (*)')
        if paths:self.add_files(paths)
    def add_files(self,paths):
        QApplication.setOverrideCursor(Qt.WaitCursor)
        errors=[]
        try:
            for file in paths[:8]:
                try:pet=self.store.add(file);self.spawn(pet)
                except Exception as e:errors.append(f'{Path(file).name}：{e}')
        finally:QApplication.restoreOverrideCursor()
        self.reload()
        if errors:QMessageBox.warning(self,'没能加入这张照片','\n'.join(errors))
    def spawn(self,pet):
        if pet['id'] in self.windows:return
        try:w=PetWindow(self.store,pet);self.windows[pet['id']]=w;w.show()
        except Exception as e:QMessageBox.warning(self,'无法显示宠物',f"{pet['name']}：{e}")
    def dismiss(self,pet):
        window=self.windows.pop(pet['id'],None)
        if window:window.close();window.deleteLater()
    def toggle(self,pet,value):
        before=pet.get('isVisible',True);pet['isVisible']=value
        try:self.store.save()
        except OSError as e:pet['isVisible']=before;QMessageBox.warning(self,'无法保存',str(e));self.reload();return
        self.spawn(pet) if value else self.dismiss(pet);self.menu()
    def toggle_all(self):
        value=not bool(self.windows)
        for pet in self.store.pets:self.toggle(pet,value)
        self.reload()
    def delete(self,pet):
        choice=QMessageBox.question(self,f"删除“{pet['name']}”？",'只会删除 Hej’s Pets 保存的副本，不会碰原照片。',QMessageBox.Yes|QMessageBox.No,QMessageBox.No)
        if choice!=QMessageBox.Yes:return
        try:self.store.remove(pet)
        except OSError as e:QMessageBox.warning(self,'无法删除',str(e));return
        self.dismiss(pet);self.reload()
    def edit(self,pet,clothing):
        try:dialog=CropDialog(self,self.store,pet,clothing)
        except Exception as e:QMessageBox.warning(self,'无法打开照片',str(e));return
        if dialog.exec()==QDialog.Accepted:
            self.dismiss(pet)
            if pet.get('isVisible',True):self.spawn(pet)
            self.reload()
    def settings_dialog(self):
        if SettingsDialog(self,self.store).exec()==QDialog.Accepted:
            self.timer.start(round(1000/self.store.settings['animationFPS']));self.last_tick=time.monotonic()
            for window in self.windows.values():window.motion.next_bubble=window.motion.now+self.store.delay()
    def toggle_pause(self):
        self.paused=not self.paused;self.pause_button.setText('继续爬行' if self.paused else '暂停爬行');self.menu()
    def tick(self):
        now=time.monotonic();dt=now-self.last_tick;self.last_tick=now
        for window in list(self.windows.values()):window.tick(dt,self.paused)
    def show_manager(self):self.showNormal();self.raise_();self.activateWindow()
    def tray_open(self,reason):
        if reason in (QSystemTrayIcon.Trigger,QSystemTrayIcon.DoubleClick):self.show_manager()
    def menu(self):
        if not hasattr(self,'tray'):return
        menu=QMenu(self)
        menu.addAction('打开宠物屋',self.show_manager);menu.addAction('添加照片…',self.choose_photos);menu.addSeparator()
        menu.addAction('继续爬行' if self.paused else '暂停爬行',self.toggle_pause);menu.addAction('暂时隐藏全部' if self.windows else '显示全部',self.toggle_all)
        menu.addSeparator();item=menu.addAction('Hej 制作 · 本地轻量版');item.setEnabled(False);menu.addAction('退出 Hej’s Pets',QApplication.instance().quit)
        old=getattr(self,'tray_menu',None);self.tray_menu=menu;self.tray.setContextMenu(menu)
        if old:old.deleteLater()
    def closeEvent(self,event):self.shutdown();QApplication.instance().quit();event.accept()
    def shutdown(self):
        self.timer.stop();self.tray.hide()
        for pet in list(self.windows.values()):pet.close()
        self.windows.clear()
