import argparse
import os
import sys
from pathlib import Path


def main():
    parser=argparse.ArgumentParser(description="Hej's Pets for Windows")
    parser.add_argument('--smoke-test',action='store_true',help='Open UI with isolated data, exercise a pet, then exit.')
    parser.add_argument('--data-dir',help='Use an explicit local data folder.')
    args=parser.parse_args()
    if args.data_dir:os.environ['HEJPETS_DATA_DIR']=args.data_dir
    from PySide6.QtCore import QLockFile, QTimer
    from PySide6.QtGui import QIcon
    from PySide6.QtWidgets import QApplication, QMessageBox
    from .data import Store, data_root
    from .ui import Manager, STYLE
    app=QApplication(sys.argv[:1]);app.setApplicationName('Hej’s Pets');app.setOrganizationName('Hej');app.setStyle('Fusion');app.setStyleSheet(STYLE)
    data_root().mkdir(parents=True,exist_ok=True)
    lock=QLockFile(str(data_root()/'app.lock'));lock.setStaleLockTime(0)
    if not lock.tryLock(100):
        QMessageBox.information(None,'Hej’s Pets','宠物屋已经在运行，请从任务栏托盘打开。');return 0
    asset=Path(getattr(sys,'_MEIPASS',Path(__file__).resolve().parents[1]))/'assets'/'AppIcon.png'
    icon=QIcon(str(asset));app.setWindowIcon(icon)
    try:store=Store();manager=Manager(store,icon)
    except Exception as e:
        QMessageBox.critical(None,'无法打开宠物屋',str(e));lock.unlock();return 1
    manager.show()
    if args.smoke_test:
        def check():
            assert manager.isVisible()
            assert len(manager.windows)==sum(bool(p.get('isVisible',True)) for p in store.pets)
            for window in manager.windows.values():
                window.motion.prepare('perimeter',window.bounds());window.tick(.03)
                window.motion.start_drag(window.motion.x+90,window.motion.y+80)
                window.motion.drag(window.motion.x+110,window.motion.y+200,.03);window.motion.end_drag();window.tick(.03)
            manager.toggle_pause();manager.toggle_pause();manager.shutdown();app.quit()
        def verify():
            try:check()
            except BaseException:
                import traceback
                traceback.print_exc()
                app.exit(1)
        QTimer.singleShot(800,verify)
    try:return app.exec()
    finally:manager.shutdown();lock.unlock()


if __name__=='__main__':
    sys.exit(main())
