import copy
import json
import math
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image, ImageDraw
from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QImage, QPainter
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QDialog
from hej_pets.data import (DEFAULTS, Store, automatic_head, crop, detect_face,
    open_image, paint_mask, painted)
from hej_pets.motion import Motion
from hej_pets.drawing import Character
from hej_pets.ui import CropDialog, Manager, PetWindow, PhotoCanvas, SettingsDialog, STYLE


def fixture(path):
    im=Image.new('RGBA',(240,320),'#BAD8CD');d=ImageDraw.Draw(im)
    d.rectangle((72,165,168,285),fill='#538C82');d.ellipse((68,22,172,157),fill='#F2C7A8')
    d.ellipse((89,72,98,81),fill='#302D29');d.ellipse((141,72,150,81),fill='#302D29');d.arc((101,98,140,120),0,180,fill='#A65B58',width=3)
    im.save(path);return im


class DataTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.source=self.root/'source.png';self.im=fixture(self.source);self.store=Store(self.root/'data')
    def tearDown(self):self.temp.cleanup()
    def test_import_persist_delete_preserves_original(self):
        p=self.store.add(self.source);restored=Store(self.store.root);self.assertEqual(restored.pets,[p]);self.assertTrue(self.store.path(p['headFilename']).exists());self.store.remove(p)
        self.assertTrue(self.source.exists());self.assertFalse(self.store.pets);self.assertFalse(list(self.store.images.iterdir()))
    def test_coordinates_mac_bottom_origin(self):
        im=Image.new('RGBA',(100,100),'red');ImageDraw.Draw(im).rectangle((0,50,99,99),fill='blue')
        self.assertEqual(crop(im,(0,.5,1,.5)).getpixel((10,10)),(255,0,0,255))
    def test_painted_selection_not_vertically_flipped(self):
        stroke={'points':[[.1,.1],[.7,.1],[.7,.35],[.1,.35]],'radius':.003,'erasing':False,'fillsInterior':True}
        result,rect=painted(self.im,[stroke]);self.assertGreater(rect[1],.60);self.assertGreater(result.width,100)
    def test_closed_lobes_and_erasing(self):
        s={'points':[[.1,.1],[.9,.9],[.1,.9],[.9,.1]],'radius':.005,'erasing':False,'fillsInterior':True}
        mask=paint_mask((100,100),[s]);self.assertGreater(mask.getpixel((50,25)),200);self.assertGreater(mask.getpixel((50,75)),200);self.assertLess(mask.getpixel((4,50)),10)
        eraser={'points':[[.5,.25]],'radius':.1,'erasing':True,'fillsInterior':False}
        self.assertLess(paint_mask((100,100),[s,eraser]).getpixel((50,25)),10)
    def test_empty_mask_rejected(self):
        with self.assertRaises(ValueError):painted(self.im,[])
    def test_automatic_head_has_transparency(self):
        head=automatic_head(self.im,(.2,.43,.6,.52));self.assertLess(head.getchannel('A').getextrema()[0],10);self.assertGreater(head.getchannel('A').getextrema()[1],240)
    def test_no_face_fallback(self):self.assertEqual(detect_face(Image.new('RGBA',(100,100),'white')),(.2,.43,.6,.52))
    def test_heic_import(self):
        import shutil
        path=self.root/'测试照片.heic'
        shutil.copyfile(Path(__file__).parent/'fixtures'/'synthetic.heic',path)
        self.assertEqual(open_image(path).size,(240,320))
        self.assertTrue(self.store.add(path)['headFilename'])
    def test_path_traversal_and_symlink_rejected(self):
        for name in ('../x.png','C:\\x.png','sub/x.png',''):
            with self.assertRaises(ValueError):self.store.path(name)
        target=self.root/'private.png';target.write_bytes(b'x');link=self.store.images/'link.png'
        try:link.symlink_to(target)
        except OSError:return
        with self.assertRaises(ValueError):self.store.path('link.png')
    def test_corrupt_data_preserved(self):
        file=self.store.root/'pets.json';file.write_text('{oops',encoding='utf8')
        with self.assertRaises(ValueError):Store(self.store.root)
        self.assertEqual(file.read_text(),'{oops')
    def test_bad_settings_repaired(self):
        self.store.settings.update(fixedMinutes=float('nan'),randomMinMinutes=20,randomMaxMinutes=1,actionMode='bad',animationFPS=4,messages=[])
        self.store.save_settings();s=Store(self.store.root).settings
        self.assertEqual(s['fixedMinutes'],2);self.assertEqual(s['randomMaxMinutes'],20);self.assertEqual(s['animationFPS'],30);self.assertTrue(s['messages'])
    def test_atomic_edit_rolls_back_on_save_failure(self):
        pet=self.store.add(self.source);before=copy.deepcopy(pet);old=self.store.path(pet['headFilename']).read_bytes()
        with patch.object(self.store,'save',side_effect=OSError('disk full')):
            with self.assertRaises(OSError):self.store.update_head(pet,'rectangle',(.1,.2,.6,.5))
        self.assertEqual(pet,before);self.assertEqual(self.store.path(pet['headFilename']).read_bytes(),old);self.assertEqual(len(list(self.store.images.iterdir())),2)
    def test_edit_clothing_reset_head_persist(self):
        pet=self.store.add(self.source);s=[{'points':[[.3,.55],[.7,.55],[.7,.8],[.3,.8]],'radius':.005,'erasing':False,'fillsInterior':True}]
        self.store.update_clothing(pet,s);self.assertTrue(self.store.path(pet['clothingTextureFilename']).exists())
        old=self.store.path(pet['clothingTextureFilename'])
        self.store.update_clothing(pet);self.assertIsNone(pet['clothingTextureFilename']);self.assertFalse(old.exists())
        self.store.update_head(pet,'freehand',strokes=s);self.assertEqual(Store(self.store.root).pets[0]['headMaskStrokes'],s)


class MotionTests(unittest.TestCase):
    def setUp(self):
        self.s=copy.deepcopy(DEFAULTS);self.s['actionMode']='perimeter';self.m=Motion(20,0,self.s,lambda:60);self.bounds=(0,800,0,500)
    def test_perimeter_traverses_four_corners(self):
        self.m.x=0;self.m.advance_perimeter(800+500+800+500,self.bounds);self.assertEqual(self.m.edge,'bottom');self.assertEqual((self.m.x,self.m.y),(0,0))
    def test_corner_residual_distance(self):
        self.m.x=799;self.m.advance_perimeter(10,self.bounds);self.assertEqual(self.m.edge,'right');self.assertEqual(self.m.y,9)
    def test_click_reaction_returns_same_wall(self):
        self.m.edge='right';self.m.x=800;self.m.y=200;self.m.observed='perimeter';self.m.action='perimeter'
        self.m.start_drag(900,270);self.m.end_drag()
        for _ in range(18):self.m.tick(.06,self.bounds)
        self.assertEqual(self.m.state,'walking');self.assertEqual(self.m.edge,'right')
    def test_fall_bounce_and_resume(self):
        self.m.y=350;self.m.start_drag(100,400);self.m.drag(150,500,.05);self.m.end_drag();states=set()
        for _ in range(160):self.m.tick(.03,self.bounds);states.add(self.m.state)
        self.assertIn('landed',states);self.assertEqual(self.m.state,'walking');self.assertGreater(self.m.bounces,1)
    def test_pause_and_fps_independence(self):
        self.m.observed='perimeter';self.m.action='perimeter';phase=self.m.phase
        self.m.tick(.05,self.bounds,True);self.assertEqual(self.m.phase,phase);self.assertEqual(self.m.x,20)
        a=Motion(20,0,self.s,lambda:60);b=Motion(20,0,self.s,lambda:60)
        for _ in range(30):a.tick(1/30,self.bounds)
        for _ in range(60):b.tick(1/60,self.bounds)
        self.assertAlmostEqual(a.x,b.x,places=6)
    def test_settings_change_does_not_teleport_drag(self):
        self.m.start_drag(100,100);self.m.drag(300,400,.03);x,y=self.m.x,self.m.y
        self.s['actionMode']='dance';self.m.tick(.03,self.bounds);self.assertEqual((self.m.x,self.m.y),(x,y));self.assertEqual(self.m.state,'dragging')
    def test_tiny_screen_terminates(self):
        self.m.advance_perimeter(100,(0,0,0,0));self.assertEqual(self.m.x,0)


class UITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app=QApplication.instance() or QApplication([]);cls.app.setStyle('Fusion');cls.app.setStyleSheet(STYLE)
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();root=Path(self.temp.name);self.source=root/'test.png';self.im=fixture(self.source);self.store=Store(root/'data');self.pet=self.store.add(self.source)
    def tearDown(self):self.app.processEvents();self.temp.cleanup()
    def test_all_poses_and_edges_render_nonempty_transparent(self):
        char=Character(self.store,self.pet);m=Motion(0,0,self.store.settings,self.store.delay)
        for action in ('dockCrawl','perimeter','dance','hop'):
            for state in ('walking','dragging','falling','landed','reacting','climbing'):
                for edge in ('bottom','right','top','left'):
                    m.action=action;m.state=state;m.edge=edge;m.bubble='陪你一会儿呀';m.phase=2
                    im=QImage(214,214,QImage.Format_ARGB32_Premultiplied);im.fill(Qt.transparent);p=QPainter(im);char.paint(p,m);p.end()
                    self.assertEqual(im.pixelColor(0,0).alpha(),0)
                    self.assertTrue(any(im.pixelColor(x,y).alpha()>100 for x in range(4,214,10) for y in range(4,214,10)))
    def test_manager_visibility_settings_and_exit(self):
        from PySide6.QtGui import QIcon
        manager=Manager(self.store,QIcon());manager.show();self.app.processEvents()
        self.assertEqual(len(manager.windows),1);manager.toggle(self.pet,False);self.assertFalse(manager.windows);manager.toggle(self.pet,True);self.assertEqual(len(manager.windows),1)
        manager.toggle_pause();self.assertTrue(manager.paused);manager.toggle_pause()
        settings=SettingsDialog(manager,self.store);settings.messages.setPlainText('测试一\n测试二');settings.fps.setCurrentText('60 FPS');settings.save()
        self.assertEqual(self.store.settings['messages'],['测试一','测试二']);self.assertEqual(self.store.settings['animationFPS'],60)
        editor=CropDialog(manager,self.store,self.pet);editor.canvas.mode='rectangle';editor.canvas.rect=QRectF(.2,.1,.6,.5);editor.commit();self.assertEqual(editor.result(),QDialog.Accepted)
        manager.shutdown();manager.close();self.assertFalse(manager.windows);self.assertFalse(manager.timer.isActive())
    @unittest.skipUnless(os.name=='nt','Windows native flags')
    def test_overlay_does_not_activate_or_create_taskbar_button(self):
        import ctypes
        window=PetWindow(self.store,self.pet);window.show();self.app.processEvents()
        user32=ctypes.windll.user32
        user32.GetWindowLongW.argtypes=[ctypes.c_void_p,ctypes.c_int];user32.GetWindowLongW.restype=ctypes.c_long
        styles=user32.GetWindowLongW(int(window.winId()),-20)
        self.assertTrue(styles & 0x00000080)  # WS_EX_TOOLWINDOW
        self.assertTrue(styles & 0x00080000)  # WS_EX_LAYERED
        self.assertTrue(styles & 0x08000000)  # WS_EX_NOACTIVATE
        self.assertTrue(styles & 0x00000008)  # WS_EX_TOPMOST
        window.close()

    def test_rectangle_resize_and_paint_undo(self):
        canvas=PhotoCanvas(self.im,self.pet);canvas.resize(720,570);canvas.show();self.app.processEvents();canvas.mode='rectangle'
        r=canvas.image_rect();start=QPointF(r.x()+r.width()*.02,r.y()+r.height()*.02).toPoint();end=QPointF(r.x()+r.width()*.5,r.y()+r.height()*.5).toPoint()
        QTest.mousePress(canvas,Qt.LeftButton,pos=start);QTest.mouseMove(canvas,end);QTest.mouseRelease(canvas,Qt.LeftButton,pos=end)
        self.assertGreater(canvas.rect.width(),.4);canvas.mode='brush'
        QTest.mousePress(canvas,Qt.LeftButton,pos=end);QTest.mouseRelease(canvas,Qt.LeftButton,pos=end);self.assertEqual(len(canvas.strokes),1);canvas.undo();self.assertFalse(canvas.strokes);canvas.close()


if __name__=='__main__':unittest.main()
