"""Animation parameters ported from Sources/HejPets.swift (bottom-left coordinates)."""
import math
import random
from .data import clamp


class Motion:
    def __init__(self, x, floor, settings, delay):
        self.x,self.y=x,floor
        self.settings,self.delay=settings,delay
        self.state='walking';self.edge='bottom';self.action='dockCrawl'
        self.phase=0.;self.direction=1;self.vx=self.vy=0.
        self.now=0.;self.state_time=0.;self.bubble=None;self.bubble_until=0.
        self.next_bubble=delay();self.next_action=5.;self.observed=None
        self.drag_distance=0.;self.bounces=0;self.return_to_track=False

    def say(self, dragging=False, duration=3.2):
        pool=self.settings['dragMessages' if dragging else 'messages']
        self.bubble=random.choice(pool) if pool else ('轻一点呀～' if dragging else '陪陪我嘛')
        self.bubble_until=self.now+duration

    def start_drag(self, x, y):
        self.offset=(x-self.x,y-self.y);self.last_mouse=(x,y)
        self.drag_distance=0;self.drag_edge=self.edge
        self.state='dragging';self.state_time=0;self.return_to_track=False
        self.say(True,2.5)

    def drag(self, x,y,dt):
        if self.state!='dragging':return
        dx,dy=x-self.last_mouse[0],y-self.last_mouse[1]
        self.vx=clamp(dx/max(.008,dt),-900,900)
        self.vy=clamp(dy/max(.008,dt),-900,900)
        self.drag_distance+=math.hypot(dx,dy)
        if self.drag_distance>=7:self.edge='bottom'
        self.last_mouse=(x,y)
        self.x,self.y=x-self.offset[0],y-self.offset[1]

    def end_drag(self):
        if self.state!='dragging':return
        self.state_time=0
        if self.drag_distance<7:
            self.edge=self.drag_edge;self.return_to_track=True;self.state='reacting'
            self.vx=self.vy=0
        else:
            self.released_y=self.y;self.vx*=.12;self.vy*=.10
            self.edge='bottom';self.state='falling';self.bounces=0

    def prepare(self, action, bounds):
        left,right,bottom,top=bounds
        self.action=action;self.edge='bottom';self.y=bottom
        self.x=clamp(self.x,left,right)
        if action=='perimeter':self.direction=1

    def advance_perimeter(self,distance,bounds):
        left,right,bottom,top=bounds
        remaining=max(0,distance)
        for _ in range(8):
            if remaining<=.0001:break
            if self.edge=='bottom':
                step=min(remaining,max(0,right-self.x));self.x+=step;self.y=bottom
                if right-self.x<.001:self.edge='right';self.x=right
            elif self.edge=='right':
                step=min(remaining,max(0,top-self.y));self.y+=step;self.x=right
                if top-self.y<.001:self.edge='top';self.y=top
            elif self.edge=='top':
                step=min(remaining,max(0,self.x-left));self.x-=step;self.y=top
                if self.x-left<.001:self.edge='left';self.x=left
            else:
                step=min(remaining,max(0,self.y-bottom));self.y-=step;self.x=left
                if self.y-bottom<.001:self.edge='bottom';self.y=bottom
            remaining-=step
        self.direction=1

    def tick(self,dt,bounds,paused=False):
        dt=clamp(dt,.001,.06);self.now+=dt
        if self.bubble is not None and self.now>=self.bubble_until:self.bubble=None
        if paused:return
        self.phase+=dt*(15 if self.state=='dragging' else 9)
        self.state_time+=dt
        left,right,bottom,top=bounds
        selected=self.settings['actionMode']
        if self.observed!=selected and self.state=='walking':
            self.observed=selected
            self.prepare('dockCrawl' if selected=='mixed' else selected,bounds)
            self.next_action=self.now+random.uniform(5,9)
        if selected=='mixed' and self.now>=self.next_action and self.state=='walking':
            self.prepare(random.choice([v for v in ('dockCrawl','perimeter','dance','hop') if v!=self.action]),bounds)
            self.next_action=self.now+random.uniform(5,10)
        if self.now>=self.next_bubble and self.state not in ('dragging','falling'):
            self.say();self.next_bubble=self.now+self.delay()
        if self.state=='walking':
            if self.action=='perimeter':self.advance_perimeter(48*dt,bounds)
            else:
                self.edge='bottom'
                if self.action in ('dockCrawl','hop'):
                    self.x+=self.direction*(48 if self.action=='dockCrawl' else 20)*dt
                    if self.x<left:self.x=left;self.direction=1
                    if self.x>right:self.x=right;self.direction=-1
                self.y=bottom+(math.sin(self.phase*1.4)*1.2 if self.action=='dockCrawl' else abs(math.sin(self.phase*.62))*27 if self.action=='hop' else 0)
        elif self.state=='falling':
            self.vy-=860*dt;self.x+=self.vx*dt;self.y+=self.vy*dt
            if self.x<left:self.x=left;self.vx=abs(self.vx)*.55
            if self.x>right:self.x=right;self.vx=-abs(self.vx)*.55
            if self.y<=bottom:
                self.y=bottom;self.bounces+=1
                if self.bounces==1 and self.released_y-self.y>150:
                    self.vy=max(105,abs(self.vy)*.22);self.vx*=.55
                else:self.vx=self.vy=0;self.state='landed';self.state_time=0
        elif self.state=='landed' and self.state_time>1.05:
            self.state='walking';self.state_time=0
        elif self.state=='reacting' and self.state_time>.95:
            if self.return_to_track:self.state='walking';self.return_to_track=False
            else:self.state='falling' if abs(self.y-bottom)>12 else 'walking';self.released_y=self.y
            self.state_time=0
        elif self.state=='climbing':
            self.y+=170*dt;self.x+=math.sin(self.phase*2.1)*13*dt
            if self.y>=bottom:self.y=bottom;self.state='walking';self.state_time=0
