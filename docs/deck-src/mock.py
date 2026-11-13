from playwright.sync_api import sync_playwright

def ic(name, s=20, extra=''):
    P = {
     'menu':'<path d="M4 7h16M4 12h16M4 17h16"/>','plus':'<path d="M12 5v14M5 12h14"/>','up':'<path d="M12 19V5M6 11l6-6 6 6"/>',
     'globe':'<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3.5 3.5 3.5 14.5 0 18M12 3c-3.5 3.5-3.5 14.5 0 18"/>',
     'mic':'<rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
     'chat':'<path d="M4 5h16v11H9l-5 4z"/>','code':'<path d="M8 7l-5 5 5 5M16 7l5 5-5 5"/>',
     'build':'<path d="M14 4l6 6-3 3-6-6zM12 9L4 17v3h3l8-8"/>','edit':'<path d="M4 20h4L19 9l-4-4L4 16z"/>',
     'check':'<path d="M5 12l5 5 9-10"/>','close':'<path d="M6 6l12 12M18 6L6 18"/>','back':'<path d="M15 5l-7 7 7 7"/>',
     'tune':'<path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="17" r="2"/>',
     'copy':'<rect x="8" y="8" width="11" height="11" rx="2"/><path d="M5 15V6a1 1 0 0 1 1-1h9"/>',
     'share':'<path d="M12 15V4M8 8l4-4 4 4M5 13v6h14v-6"/>','vol':'<path d="M4 10v4h4l5 4V6L8 10zM16 9a4 4 0 0 1 0 6"/>',
     'refresh':'<path d="M19 8a7 7 0 1 0 1 6M19 4v4h-4"/>','search':'<circle cx="11" cy="11" r="6"/><path d="M16 16l4 4"/>',
     'bulb':'<path d="M9 18h6M10 21h4M12 3a6 6 0 0 0-3 11c.6.5 1 1.2 1 2h4c0-.8.4-1.5 1-2a6 6 0 0 0-3-11z"/>',
     'photo':'<rect x="4" y="5" width="16" height="14" rx="2"/><circle cx="9" cy="10" r="1.5"/><path d="M4 17l5-4 4 3 3-2 4 3"/>',
     'pen':'<path d="M4 20l3-1L19 7l-2-2L5 17z"/>','bolt':'<path d="M13 3L5 13h6l-1 8 8-10h-6z"/>',
     'zip':'<rect x="5" y="3" width="14" height="18" rx="2"/><path d="M12 3v4M12 9v2M12 13v2"/>','lock':'<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
     'money':'<circle cx="12" cy="12" r="9"/><path d="M12 7v10M9.5 9.5c0-1.2 1.2-2 2.5-2s2.5.8 2.5 2-1.2 1.6-2.5 2-2.5.8-2.5 2 1.2 2 2.5 2 2.5-.8 2.5-2"/>',
     'down':'<path d="M12 5v14M6 13l6 6 6-6"/>','file':'<path d="M7 3h7l4 4v14H7z"/>','install':'<rect x="7" y="3" width="10" height="18" rx="2"/><path d="M12 8v6M9.5 12l2.5 2.5 2.5-2.5"/>',
     'qr':'<rect x="4" y="4" width="6" height="6"/><rect x="14" y="4" width="6" height="6"/><rect x="4" y="14" width="6" height="6"/><path d="M14 14h2v2M20 14v6M14 20h3"/>',
     'warn':'<path d="M12 4l9 16H3zM12 10v4M12 17v.5"/>','fp':'<path d="M7 11a5 5 0 0 1 10 0M5 14a7 7 0 0 1 14 0M9 20c1-2 1-5 1-9M13 20c1.5-3 1.5-6 1.5-9"/>'}
    return f'<svg viewBox="0 0 24 24" width="{s}" height="{s}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="{extra}">{P[name]}</svg>'

CSS = """
*{box-sizing:border-box;margin:0;padding:0}
body{background:transparent;font-family:'Inter',sans-serif;color:#E6E7EE;-webkit-font-smoothing:antialiased}
.phone{width:380px;height:760px;padding:10px;background:#0b0b0e;border-radius:48px;box-shadow:inset 0 0 0 2px #2b2c35}
.screen{position:relative;width:360px;height:740px;border-radius:38px;overflow:hidden;background:#000}
.glow{position:absolute;inset:0;background:radial-gradient(ellipse at 18% 108%,rgba(27,47,158,.85),transparent 58%),radial-gradient(ellipse at 88% 110%,rgba(79,107,255,.7),transparent 52%),radial-gradient(ellipse at 52% 122%,rgba(122,77,255,.6),transparent 48%)}
.sb{position:absolute;top:0;left:0;right:0;height:32px;display:flex;justify-content:space-between;align-items:center;padding:6px 24px 0;font-size:12.5px;font-weight:600;z-index:9}
.body{position:absolute;top:32px;left:0;right:0;bottom:0}
.top{display:flex;align-items:center;gap:6px;padding:4px 12px}
.sp{flex:1}.mode{display:flex;background:#1d1d22;border-radius:999px;padding:3px}
.seg{height:34px;width:40px;border-radius:17px;display:flex;align-items:center;justify-content:center;gap:5px;color:#a9abb8}
.seg.on{width:88px;background:#b8c3ff;color:#0e1f6b;font-weight:600;font-size:13px}
.av{width:32px;height:32px;border-radius:50%;background:#b8c3ff;color:#0e1f6b;font-weight:700;display:flex;align-items:center;justify-content:center;font-size:14px;margin-left:4px}
.card{background:rgba(29,29,34,.94);border-radius:22px;padding:14px;margin:0 14px 10px}
.h1{font-size:17px;font-weight:600}.h2{font-size:14px;font-weight:600}.sub{font-size:11.5px;color:#a9abb8;line-height:1.4}.p{font-size:12.5px;line-height:1.45}
.btn{height:42px;border-radius:21px;background:#b8c3ff;color:#0e1f6b;font-weight:600;font-size:13.5px;display:flex;align-items:center;justify-content:center;gap:7px;padding:0 16px}
.btn.tonal{background:#2d3567;color:#dde1ff}.btn.out{background:transparent;border:1px solid #474d6b;color:#c9ceff}.btn.s{height:36px;font-size:12.5px;padding:0 13px}
.row{display:flex;align-items:center;gap:8px}.wrap{display:flex;flex-wrap:wrap;gap:6px}
.field{background:#26262c;border-radius:14px;padding:10px 12px;font-size:12.5px;line-height:1.4}
.chip{border:1px solid #3b405a;border-radius:999px;padding:5px 10px;font-size:11px;display:inline-flex;align-items:center;gap:4px;color:#d4d6e2}
.chip.on{background:#2d3567;border-color:#2d3567;color:#dde1ff}
.orb{position:relative;border-radius:50%;background:conic-gradient(from 30deg,#4f6bff,#7a4dff,#ffffff,#1b2f9e,#4f6bff);-webkit-mask:radial-gradient(circle,transparent 46%,#000 47%);box-shadow:0 0 40px rgba(79,107,255,.5)}
.orbw{position:relative;display:inline-block}.orbw i{position:absolute;border-radius:50%;background:#fff}
.badge{position:absolute;width:22px;height:22px;border-radius:50%;background:#ffb300;color:#111;font-weight:700;font-size:12px;display:flex;align-items:center;justify-content:center;box-shadow:0 0 0 3px rgba(0,0,0,.55);z-index:20}
.green{color:#34c759}.amber{color:#ffb300}.muted{color:#a9abb8}
.comp{position:absolute;left:12px;right:12px;bottom:16px;height:54px;border-radius:28px;background:#1f1f25;border:1px solid #33343f;display:flex;align-items:center;padding:0 8px;gap:2px;box-shadow:0 0 22px rgba(79,107,255,.25)}
.ci{width:34px;height:34px;display:flex;align-items:center;justify-content:center;color:#c8cad6;position:relative}
.send{width:36px;height:36px;border-radius:50%;background:#b8c3ff;color:#0e1f6b;display:flex;align-items:center;justify-content:center}
.bar{display:flex;gap:4px;padding:2px 14px 8px}.bar b{flex:1;height:4px;border-radius:4px;background:#3a3d4f}.bar b.on{background:#b8c3ff}
.sheetbg{position:absolute;inset:0;background:rgba(0,0,0,.62);z-index:10}
.sheet{position:absolute;left:0;right:0;bottom:0;background:#1d1d22;border-radius:26px 26px 0 0;padding:10px 20px 22px;z-index:11}
.grab{width:34px;height:4px;border-radius:4px;background:#555a70;margin:0 auto 12px}
.tick{width:22px;height:22px;border-radius:50%;background:#34c759;color:#06210f;display:flex;align-items:center;justify-content:center}
.sw{width:40px;height:24px;border-radius:12px;background:#b8c3ff;position:relative}.sw i{position:absolute;right:3px;top:3px;width:18px;height:18px;border-radius:50%;background:#0e1f6b}
.sl{height:4px;border-radius:4px;background:#3a3d4f;position:relative;margin:12px 6px}.sl b{position:absolute;left:0;top:0;height:4px;border-radius:4px;background:#b8c3ff}.sl i{position:absolute;top:-8px;width:20px;height:20px;border-radius:50%;background:#b8c3ff}
"""

def orb(size, dot=True):
    d = size*0.17
    return (f'<span class="orbw" style="width:{size}px;height:{size}px"><span class="orb" style="width:{size}px;height:{size}px;display:block"></span>'
            f'<i style="width:{d}px;height:{d}px;left:{size*0.74}px;top:{size*0.14}px"></i></span>')

def top(sel, plus=False):
    items = [('Chat','chat'),('Code','code'),('Build','build')]
    segs = ''.join(f'<div class="seg{" on" if i==sel else ""}">{ic(k,16)}{"<span>"+n+"</span>" if i==sel else ""}</div>' for i,(n,k) in enumerate(items))
    return f'<div class="top">{ic("menu",22,"color:#e6e7ee")}<div class="mode">{segs}</div><div class="sp"></div>{ic("plus" if plus else "edit",21,"color:#e6e7ee")}<div class="av">S</div></div>'

def bhead(title, stage, label):
    bars = ''.join(f'<b class="{"on" if i<stage else ""}"></b>' for i in range(6))
    return (f'<div class="row" style="padding:2px 12px 0">{ic("back",22)}<div class="h2" style="flex:1">{title}</div><div style="font-size:11px;color:#b8c3ff;font-weight:600">{label}</div></div><div class="bar" style="padding-top:8px">{bars}</div>')

def shell(inner, glow=True):
    return (f'<div class="phone"><div class="screen">{"<div class=glow></div>" if glow else ""}<div class="sb"><span>9:41</span><span style="letter-spacing:2px">▮▮▮ 100%</span></div>'
            f'<div class="body">{inner}</div></div></div>')

def composer(badges=False, text='Ask AIy', send=False):
    b = lambda n: f'<span class="badge" style="top:-34px;left:6px">{n}</span>' if badges else ''
    return (f'<div class="comp"><div class="ci">{ic("plus",22)}{b(1)}</div><div style="flex:1;font-size:14px;color:#8b8d9c;padding-left:2px">{text}</div>'
            f'<div class="ci">{ic("tune",20)}{b(2)}</div><div class="ci">{ic("globe",20)}{b(3)}</div><div class="ci">{ic("mic",20)}{b(4)}</div>'
            f'<div class="send">{ic("up",18)}</div></div>')

S = {}
# ---------------------------------------------------------------- chat home
S['chat_home'] = shell(top(0)+f'''<div style="text-align:center;margin-top:92px">{orb(84)}<div style="font-size:27px;font-weight:500;line-height:1.15;margin-top:18px">Hi Sara,<br>how can I help?</div></div>
<div style="position:absolute;left:34px;right:20px;top:420px">'''+''.join(f'<div class="row" style="padding:11px 0;gap:16px;color:#e6e7ee">{ic(i,22,"color:#a9abb8")}<div style="font-size:14.5px">{t}</div></div>' for i,t in [('bulb','Explain something simply'),('pen','Help me write a message'),('globe','What is new today?'),('photo','Ask about a photo')])+'</div>'+composer())
# ---------------------------------------------------------------- sign in
S['signin'] = shell(f'''<div style="text-align:center;padding-top:150px">{orb(112)}<div style="font-size:34px;font-weight:600;margin-top:26px">AIy</div>
<div style="font-size:15px;color:#a9abb8;line-height:1.4;margin-top:8px">Your personal AI assistant<br>and coding helper</div></div>
<div style="position:absolute;left:28px;right:28px;bottom:86px"><div class="btn" style="height:50px;font-size:15px">{ic("lock",18)} Continue with Google</div><div class="sub" style="text-align:center;margin-top:14px">One Google account is all you need.</div></div>''')
# ---------------------------------------------------------------- connect accounts
def svc(name, what, ok, opt=False, btn=None):
    right = f'<div class="tick">{ic("check",15)}</div>' if ok else ''
    steps = '' if ok else f'<div class="sub" style="margin-top:8px">1. Tap Connect.<br>2. Sign in with Google and approve.</div><div class="row" style="margin-top:8px"><div class="btn tonal s">{btn}</div><div class="sub" style="color:#b8c3ff">Paste it myself</div></div>'
    return (f'<div class="card" style="padding:12px"><div class="row"><div style="width:34px;height:34px;border-radius:50%;background:rgba(184,195,255,.16);display:flex;align-items:center;justify-content:center;color:#b8c3ff">{ic("bolt",17)}</div>'
            f'<div style="flex:1"><div class="h2">{name} <span class="sub">{"optional" if opt else ""}</span></div><div class="sub">{what}</div></div>{right}</div>{steps}</div>')
S['connect'] = shell(f'''<div style="padding:14px 18px 8px">{orb(46)}<div style="font-size:23px;font-weight:500;margin-top:10px">Welcome, Sara</div><div class="sub" style="margin-top:4px">Let's connect your free AI accounts. Use the same Google account for all of them.</div></div>'''
  + svc('Google Gemini','The main free brain: chat, photos and live search.',True)
  + svc('OpenRouter','Many models for coding. Also the backup when Gemini is busy.',True)
  + svc('GitHub','Open your projects and build the app for you.',False,True,'Connect')
  + f'<div style="position:absolute;left:14px;right:14px;bottom:18px"><div class="btn" style="height:48px">Start using AIy</div></div>')
# ---------------------------------------------------------------- chat answer
S['chat_answer'] = shell(top(0)+f'''<div style="padding:6px 14px 0">
<div style="margin-left:46px;background:rgba(184,195,255,.2);border-radius:20px 20px 6px 20px;padding:10px 13px;font-size:13px;line-height:1.4">Help me write a polite message asking to move a meeting to tomorrow.</div>
<div class="p" style="margin-top:14px"><div style="font-weight:600;margin-bottom:6px">Here is a short, polite message:</div>
<div style="background:#1d1d22;border-radius:14px;padding:11px 12px;font-size:12.5px;line-height:1.5;color:#e3e4ee">Hi Omar, I hope you are well. Would it be possible to move our meeting to tomorrow? I am free at the same time, or whenever suits you best. Thank you for understanding.</div>
<div class="p" style="margin-top:10px">Want it shorter, or more formal?</div>
<div class="row" style="margin-top:10px;gap:4px"><span class="chip on" style="gap:4px;background:rgba(184,195,255,.14);border:none;color:#b8c3ff">{ic("bolt",12)} Gemini · gemini-3.8-flash</span></div>
<div class="row" style="margin-top:8px;gap:14px;color:#a9abb8">{ic("copy",17)}{ic("refresh",17)}{ic("vol",17)}{ic("share",17)}</div></div></div>'''+composer(True))
# ---------------------------------------------------------------- build: describe
S['build_describe'] = shell(top(2,True)+bhead('New app',1,'Idea')+f'''
<div class="card" style="padding:13px"><div class="h1">Explain your app</div><div class="sub" style="margin:3px 0 9px">Say what it is for, who uses it and what it should do.</div>
<div class="field" style="height:128px">A habit tracker. I add daily habits, tick them off each day, and see how many days in a row I did them. Everything stays on my phone.</div>
<div class="sub" style="margin:10px 0 6px">Or start from a ready idea</div><div class="wrap"><span class="chip">{ic("bolt",12)} Habit tracker</span><span class="chip">{ic("bolt",12)} Expense log</span><span class="chip">{ic("bolt",12)} Quiz game</span></div></div>
<div class="card" style="padding:13px"><div class="row"><div class="h2" style="flex:1">How many questions should I ask?</div><div style="font-size:24px;font-weight:600;color:#b8c3ff">4</div></div>
<div class="sl"><b style="width:10%"></b><i style="left:7%"></i></div><div class="sub">Quick start: I will make most choices myself.<br>Each question has suggested answers you can tap.</div></div>
<div style="padding:0 14px"><div class="btn">Next: choose the look</div></div>''')
# ---------------------------------------------------------------- build: look
def tile(kind, sel, letter='S'):
    inner = {'letter':f'<span style="font-size:30px;font-weight:700;color:#fff">{letter}</span>',
             'ring':'<span style="width:26px;height:26px;border-radius:50%;border:5px solid #fff;display:block"></span>',
             'spark':'<svg viewBox="0 0 24 24" width="36" height="36"><path d="M12 2l2.2 7.8L22 12l-7.8 2.2L12 22l-2.2-7.8L2 12l7.8-2.2z" fill="#fff"/></svg>',
             'dots':'<svg viewBox="0 0 24 24" width="34" height="34"><circle cx="12" cy="7" r="3.2" fill="#fff"/><circle cx="7" cy="16" r="3.2" fill="#fff"/><circle cx="17" cy="16" r="3.2" fill="#fff"/></svg>'}[kind]
    return (f'<div style="text-align:center"><div style="width:60px;height:60px;border-radius:15px;background:linear-gradient(135deg,#1b2f9e,#4f6bff 55%,#7a4dff);display:flex;align-items:center;justify-content:center;'
            f'outline:{"2.5px solid #b8c3ff" if sel else "none"};outline-offset:3px">{inner}</div><div class="sub" style="margin-top:6px;font-size:10.5px">{kind.title()}</div></div>')
def sw(c1,c2,c3,on=False,name=''):
    return (f'<div style="text-align:center"><div style="width:40px;height:40px;border-radius:50%;background:conic-gradient({c1},{c2},{c3},{c1});outline:{"2.5px solid #fff" if on else "none"};outline-offset:2px"></div><div class="sub" style="font-size:9.5px;margin-top:4px">{name}</div></div>')
S['build_look'] = shell(top(2,True)+bhead('New app',2,'Look')+f'''
<div class="card"><div class="h1">Name and icon</div>
<div class="row" style="margin:10px 0"><div class="field" style="flex:1">Streaks</div><div class="btn out s">Suggest</div></div>
<div class="h2" style="margin:12px 0 8px">Icon style</div><div class="row" style="justify-content:space-between">{tile('letter',False)}{tile('ring',False)}{tile('spark',True)}{tile('dots',False)}</div></div>
<div class="card"><div class="h1">Theme and colours</div><div class="row" style="justify-content:space-between;margin-top:12px">{sw('#1B2F9E','#4F6BFF','#7A4DFF',False,'Midnight')}{sw('#00695C','#00BFA5','#7C4DFF',True,'Aurora')}{sw('#AD1457','#FF6D3A','#FFB300',False,'Sunset')}{sw('#6A1B9A','#E91E63','#FF8A65',False,'Rose')}{sw('#1B5E20','#2E9E5B','#C0CA33',False,'Forest')}</div>
<div class="row" style="margin-top:14px;background:#26262c;border-radius:999px;padding:3px"><div style="flex:1;text-align:center;padding:7px;font-size:12px;color:#a9abb8">Auto</div><div style="flex:1;text-align:center;padding:7px;font-size:12px;color:#a9abb8">Light</div><div style="flex:1;text-align:center;padding:7px;font-size:12px;background:#b8c3ff;color:#0e1f6b;border-radius:999px;font-weight:600">Dark</div></div></div>
<div class="row" style="padding:0 14px"><div class="btn out" style="flex:1">Back</div><div class="btn" style="flex:2">Start the questions</div></div>''')
# ---------------------------------------------------------------- build: question
def opt(t, on=False): return f'<div style="background:{"rgba(184,195,255,.18)" if on else "rgba(29,29,34,.94)"};border:1px solid {"#b8c3ff" if on else "#33343f"};border-radius:18px;padding:13px 15px;font-size:13.5px;font-weight:600;margin-bottom:10px">{t}</div>'
S['build_question'] = shell(top(2,True)+bhead('Streaks',3,'Questions')+f'''
<div style="padding:4px 16px"><div class="row"><div style="font-size:12.5px;font-weight:600;color:#b8c3ff;flex:1">Question 2 of 4</div><div class="sub" style="color:#b8c3ff">Change the look</div></div>
<div class="sl" style="margin:8px 0 22px"><b style="width:50%"></b></div>
<div style="font-size:21px;line-height:1.25;font-weight:500;margin-bottom:20px">What should happen when you miss a day?</div>
{opt('The streak starts again',True)}{opt('Nothing, the streak stays')}{opt('Show a friendly reminder')}
<div class="field" style="margin-top:14px;display:flex;align-items:center;gap:8px;color:#8b8d9c">{ic("mic",18)}<span style="flex:1">Or type your own answer</span><span class="send" style="width:30px;height:30px;opacity:.5">{ic("up",15)}</span></div>
<div class="row" style="margin-top:12px"><div class="muted row" style="gap:4px;font-size:12.5px">{ic("back",16)} Back</div><div class="sp"></div><div style="font-size:12.5px;color:#b8c3ff;font-weight:600">You decide</div></div>
<div class="sub" style="margin-top:6px">"You decide" lets AIy choose a sensible answer.</div></div>''')
# ---------------------------------------------------------------- build: brief
def ck(t): return f'<div class="row" style="padding:5px 0;font-size:12.5px"><span style="width:18px;height:18px;border-radius:5px;background:#b8c3ff;color:#0e1f6b;display:flex;align-items:center;justify-content:center">{ic("check",13)}</span>{t}</div>'
S['build_brief'] = shell(top(2,True)+bhead('Streaks',4,'Brief')+f'''
<div class="card"><div class="h1">Your app brief</div><div class="sub" style="margin:3px 0 8px">This is what the code will be written from. Change anything you like.</div>
<div class="field" style="font-size:11.5px;line-height:1.5;height:216px;overflow:hidden"><b style="font-size:14px"># Streaks</b><br><b>## What it does</b><br>A simple habit tracker. You add daily habits, tick them off, and see your streak in days.<br><b>## Screens</b><br>- <b>Today</b>: the habits for today with tick boxes<br>- <b>Streaks</b>: the longest streak of each habit<br>- <b>Add habit</b>: a name and a colour<br><b>## Data and features</b><br>- Saved on the phone only<br>- A missed day restarts the streak</div></div>
<div class="card" style="padding:12px 14px"><div class="h2">Screens</div><div class="sub" style="margin-bottom:4px">Untick a screen to leave it out of this first version.</div>{ck('Today')}{ck('Streaks')}{ck('Add habit')}</div>
<div class="row" style="padding:0 14px"><div class="btn out s" style="flex:1">Questions</div><div class="btn out s" style="flex:1">Write it again</div></div>''')
# ---------------------------------------------------------------- build: write
S['build_write'] = shell(top(2,True)+bhead('Streaks',5,'Write')+f'''
<div class="card"><div class="h1">Who writes the code?</div><div class="sub" style="margin:3px 0 10px">AIy plans the files with a free model, then the model you choose writes them.</div>
<div class="row" style="background:#26262c;border-radius:16px;padding:12px 14px"><div style="flex:1"><div class="h2">Example coding model</div><div class="sub">$0.30 in · $1.20 out per 1M tokens</div></div>{ic("down",18,"transform:rotate(0)")}</div>
<div class="sub" style="margin-top:12px">Estimated cost: about $0.04. It can never cost more than $0.25 in total, even with the automatic fix rounds.</div>
<div class="sub" style="margin-top:10px">After the code is written AIy checks it. If something is wrong, it asks the same model to fix it, up to two more times.</div></div>
<div class="row" style="padding:0 14px;margin-top:8px"><div class="btn out" style="flex:1">Brief</div><div class="btn" style="flex:2">{ic("bolt",17)} Write the app</div></div>
<div style="position:absolute;left:16px;right:16px;bottom:22px;background:#e6e7ee;color:#1a1a20;border-radius:999px;padding:11px 14px" class="row">{orb(26)}<div style="font-size:12.5px;font-weight:600">Writing the code with Example coding model…</div></div>''')
# ---------------------------------------------------------------- build: done
S['build_done'] = shell(top(2,True)+bhead('Streaks',6,'Done')+f'''
<div class="card"><div class="row"><div style="width:52px;height:52px;border-radius:13px;background:linear-gradient(135deg,#00695C,#00BFA5 55%,#7C4DFF);display:flex;align-items:center;justify-content:center"><svg viewBox="0 0 24 24" width="30" height="30"><path d="M12 2l2.2 7.8L22 12l-7.8 2.2L12 22l-2.2-7.8L2 12l7.8-2.2z" fill="#fff"/></svg></div>
<div><div class="h1">Streaks is written</div><div class="sub">9 files · Example model · $0.04</div></div></div>
<div class="wrap" style="margin-top:12px"><div class="btn s">{ic("code",15)} Keep improving in Code</div><div class="btn out s">{ic("down",15)} Save the zip</div><div class="btn out s">{ic("share",15)} Share</div></div></div>
<div class="card"><div class="h2">What to do with it</div><div class="sub" style="margin:3px 0 10px">A zip you can open on your PC, or push it to a new GitHub repository and let GitHub build the APK.</div><div class="h2" style="margin-bottom:6px">Publish</div><div class="btn tonal">{ic("up",17)} Push to GitHub</div></div>
<div class="card" style="padding:12px 14px"><div class="h2" style="margin-bottom:4px">Files</div>'''+''.join(f'<div class="row" style="padding:5px 0;font-size:11.5px;font-family:monospace"><span class="muted">{ic("file",15)}</span><span style="flex:1">{n}</span><span class="muted" style="font-family:Inter">{l} lines</span></div>' for n,l in [('lib/main.dart',62),('lib/screens/today.dart',148),('lib/screens/streaks.dart',97),('lib/models/habit.dart',41)])+'</div>')
# ---------------------------------------------------------------- version sheet
S['version'] = shell(top(2,True)+bhead('Streaks',6,'Done')+f'''<div class="card" style="opacity:.5"><div class="h1">Streaks is written</div></div>
<div class="sheetbg"></div><div class="sheet"><div class="grab"></div><div class="h1">Which version is this?</div>
<div class="sub" style="margin:4px 0 10px">The project says 1.0.0 (in pubspec.yaml). The version you choose is written there, so the app shows it.</div>
<div class="field" style="border-bottom:2px solid #b8c3ff"><span class="sub">Version</span><br><span style="font-size:15px">1.0.1</span></div>
<div class="wrap" style="margin:10px 0"><span class="chip">Same</span><span class="chip on">Small fix 1.0.1</span><span class="chip">New feature 1.1.0</span><span class="chip">Big change 2.0.0</span></div>
<div class="field" style="height:62px;color:#c8cad6">Added a Today screen with tick boxes and a streak counter.</div>
<div class="row" style="margin:12px 0 14px"><div style="flex:1"><div class="h2">Also publish a GitHub Release</div><div class="sub">A download page you can share.</div></div><div class="sw"><i></i></div></div>
<div class="row"><div class="btn out" style="flex:1">Cancel</div><div class="btn" style="flex:1">Build the app</div></div></div>''')
# ---------------------------------------------------------------- build progress
def stp(t, st):
    ico = {'d':f'<span class="green">{ic("check",17)}</span>','r':'<span style="width:15px;height:15px;border:2.5px solid #b8c3ff;border-top-color:transparent;border-radius:50%;display:inline-block"></span>','w':'<span class="muted" style="font-size:14px">○</span>'}[st]
    return f'<div class="row" style="padding:5px 0;font-size:12.5px"><span style="width:22px;display:flex;justify-content:center">{ico}</span><span style="{"color:#8b8d9c" if st=="w" else ""}">{t}</span></div>'
S['build_progress'] = shell(f'''<div class="row" style="padding:2px 12px 8px">{ic("back",22)}<div class="h2">Build on GitHub</div></div>
<div class="card"><div class="row" style="gap:12px">{orb(46)}<div><div class="h1">Building version 1.0.1</div><div class="sub">Building on GitHub (run 3): Build the debug APK</div></div></div>
<div class="sl" style="margin:14px 0 10px"><b style="width:62%"></b></div><div class="sub">A build takes a few minutes. You can leave AIy: the build keeps running on GitHub, and AIy picks it up again when you come back.</div></div>
<div class="card" style="padding:12px 14px"><div class="h2" style="margin-bottom:4px">Steps</div>{stp('Run actions/checkout','d')}{stp('Run actions/setup-java','d')}{stp('Run subosito/flutter-action','d')}{stp('Use one fixed signing key','d')}{stp('Build the debug APK','r')}{stp('Upload the app','w')}</div>
<div class="row" style="padding:0 14px"><div class="btn out s" style="flex:1">Open on GitHub</div><div class="btn out s" style="flex:1">Cancel</div></div>''')
# ---------------------------------------------------------------- build ready
S['build_ready'] = shell(f'''<div class="row" style="padding:2px 12px 8px">{ic("back",22)}<div class="h2">Build on GitHub</div></div>
<div class="card"><div class="row" style="gap:12px"><span class="green">{ic("check",44)}</span><div><div class="h1">Your app is ready</div><div class="sub">Built successfully on GitHub</div></div></div></div>
<div class="card"><div style="font-family:monospace;font-size:11.5px">streaks-1_0_1-build3.apk</div><div class="sub" style="margin:3px 0 12px">Version 1.0.1 · 19 MB</div>
<div class="wrap"><div class="btn s">{ic("install",16)} Install</div><div class="btn out s">{ic("down",15)} Save</div><div class="btn out s">{ic("share",15)} Share</div><div class="btn out s">{ic("globe",15)} Release page</div><div class="btn out s">{ic("qr",15)} QR code</div></div>
<div class="sub" style="margin-top:12px">• Version 1.0.0 -> 1.0.1 (build number 2)<br>• Release published</div></div>''')
# ---------------------------------------------------------------- code tab
S['code'] = shell(top(1)+f'''
<div class="card"><div class="row">{ic("zip",22,"color:#b8c3ff")}<div class="h2" style="flex:1">my-shop-app.zip</div>{ic("close",18)}</div>
<div class="sub" style="margin-top:6px">212 files, 6 MB in the project<br>38 source files read by AIy (the rest stays untouched in the zip)</div>
<div class="wrap" style="margin-top:10px"><div class="btn out s">{ic("bolt",14)} Explain this codebase</div><div class="btn out s">{ic("chat",14)} Ask about it</div></div></div>
<div class="card"><div class="row"><span style="width:22px;height:22px;border-radius:50%;background:#b8c3ff;color:#0e1f6b;font-size:12px;font-weight:700;display:flex;align-items:center;justify-content:center">1</span><div class="h1">What should change?</div></div>
<div class="field" style="height:70px;margin-top:10px">Add a dark mode switch to the settings page.</div>
<div class="row" style="margin:10px 0;color:#b8c3ff;font-size:12.5px;font-weight:600">{ic("photo",18)} Add a photo of the problem</div><div class="btn tonal">Find the files</div></div>
<div class="card" style="padding:12px 14px"><div class="row"><span style="width:22px;height:22px;border-radius:50%;background:#b8c3ff;color:#0e1f6b;font-size:12px;font-weight:700;display:flex;align-items:center;justify-content:center">2</span><div class="h1">Files to change</div></div>'''+''.join(f'<div class="row" style="padding:6px 0;font-size:11.5px;font-family:monospace">{ic("file",15,"color:#a9abb8")}<span style="flex:1">{n}</span>{ic("close",14,"color:#a9abb8")}</div>' for n in ['src/screens/Settings.kt','src/ui/Theme.kt','src/MainActivity.kt'])+'</div>')
# ---------------------------------------------------------------- settings
S['settings'] = shell(f'''<div class="row" style="padding:2px 12px 8px">{ic("back",22)}<div class="h1">Settings</div></div>
<div style="padding:0 18px 4px" class="h2"><span style="color:#b8c3ff">Spending</span></div>
<div class="card"><div class="row"><div style="flex:1"><div style="font-size:24px;font-weight:600;color:#b8c3ff">$0.12</div><div class="sub">this month</div></div><div style="flex:1"><div style="font-size:24px;font-weight:600">$0.86</div><div class="sub">since the start</div></div></div>
<div class="row" style="margin-top:10px;font-size:12.5px"><span style="flex:1">Streaks</span><b>$0.04</b></div><div class="row" style="margin-top:3px;font-size:12.5px"><span style="flex:1">my-shop-app</span><b>$0.08</b></div>
<div class="wrap" style="margin-top:10px"><div class="btn out s">Check my OpenRouter credit</div></div></div>
<div class="card"><div class="row"><div class="h2" style="flex:1">Spending limit for one request</div><div style="font-size:17px;font-weight:600;color:#b8c3ff">$0.25</div></div><div class="sl"><b style="width:12%"></b><i style="left:9%"></i></div></div>
<div style="padding:0 18px 4px" class="h2"><span style="color:#b8c3ff">Security and backup</span></div>
<div class="card"><div class="row"><div style="flex:1"><div class="h2">App lock</div><div class="sub">Ask for a PIN when AIy is opened again</div></div><div class="sw"><i></i></div></div>
<div class="row" style="margin-top:10px"><div style="flex:1;font-size:12.5px">Use the fingerprint too</div><div class="sw"><i></i></div></div>
<div class="wrap" style="margin-top:12px"><div class="btn out s">{ic("up",15)} Save a backup</div><div class="btn out s">{ic("down",15)} Restore</div></div></div>''')
# ---------------------------------------------------------------- test everything
def tr(name, msg, st='ok'):
    c = {'ok':'green','warn':'amber'}[st]; i = 'check' if st=='ok' else 'warn'
    return f'<div class="card" style="padding:10px 14px;margin-bottom:7px"><div class="row" style="align-items:flex-start"><span class="{c}" style="margin-top:1px">{ic(i,19)}</span><div><div class="h2" style="font-size:13px">{name}</div><div class="sub" style="font-size:10.5px">{msg}</div></div></div></div>'
S['test'] = shell(f'''<div class="row" style="padding:2px 12px 8px">{ic("back",22)}<div class="h1">Test everything</div></div>
<div class="card" style="padding:12px 14px"><div class="row" style="gap:12px"><span class="green">{ic("check",38)}</span><div class="h1">Everything works</div></div></div>'''
  + tr('This version of AIy','AIy 1.3.0 (build 1)')+tr('Internet','Connected')+tr('Key vault (encrypted keys)','Keys can be stored and read back')
  + tr('Zip engine (Code and Build tabs)','A test zip was created, read and rebuilt')+tr('Gemini','Gemini key works.')+tr('OpenRouter','OpenRouter key works.')
  + tr('Groq','Not connected (optional)','warn')
  + f'<div class="row" style="padding:2px 14px"><div class="btn out s" style="flex:1">Run again</div><div class="btn s" style="flex:1">Copy the report</div></div>')

if __name__ == '__main__':
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={'width':420,'height':800}, device_scale_factor=2)
        for k, h in S.items():
            pg.set_content(f'<html><head><style>{CSS}</style></head><body style="padding:10px">{h}</body></html>')
            pg.wait_for_timeout(120)
            pg.locator('.phone').screenshot(path=f'shots/{k}.png', omit_background=True)
        b.close()
    from PIL import Image
    names = list(S); ims = [Image.open(f'shots/{n}.png').convert('RGBA') for n in names]
    w, h = ims[0].size; cols = 8; rows = (len(ims)+cols-1)//cols; sc = 0.42
    sheet = Image.new('RGBA', (int(w*sc)*cols, int(h*sc)*rows), (230,232,245,255))
    for i, im in enumerate(ims):
        t = im.resize((int(w*sc), int(h*sc))); sheet.alpha_composite(t, ((i%cols)*int(w*sc), (i//cols)*int(h*sc)))
    sheet.convert('RGB').save('contact.png'); print(len(ims), 'screens', w, h)
