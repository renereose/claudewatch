// The entire UI — a self-contained HTML/CSS/JS document rendered in a WKWebView.
// Swift feeds it session JSON via render(...) and settings via setCfg(...); the page posts
// back user actions (focus, cfg, fit, drag) through window.webkit.messageHandlers.
let HTML = """
<!doctype html><meta charset=utf-8><style>
 *{margin:0;box-sizing:border-box;font-family:ui-monospace,Menlo,monospace;cursor:default;
    -webkit-tap-highlight-color:transparent;outline:none}
 body{background:#16181d;color:#d5d8de;padding:8px;-webkit-user-select:none}
 body.m-bubble{padding:0;background:transparent}
 .bar{display:flex;align-items:center;gap:3px;padding:2px 2px 8px;-webkit-app-region:drag}
 .grip{color:#4b5563;font-size:12px;padding:0 4px 0 2px;flex:none}
 .ttl{font-size:11px;color:#6b7280;font-weight:600;letter-spacing:.08em;text-transform:uppercase;flex:none}
 .sp{flex:1}
 .bar button{-webkit-app-region:no-drag;background:none;border:0;color:#6b7280;cursor:pointer;
    font-size:12px;padding:2px 5px;border-radius:5px;line-height:1}
 .bar button:hover{color:#d5d8de;background:#242833}
 .bar button.act,.bar button.on{color:#34d399}
 .set{display:none;flex-direction:column;gap:9px;margin:0 2px 8px;padding:9px 10px;
    background:#1a1d23;border:1px solid #2a2e37;border-radius:8px}
 .set.open{display:flex}
 .set .row{display:flex;align-items:center;gap:8px;color:#9ca3af;font-size:11px;cursor:pointer}
 .set .row *{cursor:pointer}
 .set .row:hover{color:#d5d8de}
 .set .k{flex:1}
 .set input[type=range]{width:96px;height:3px;accent-color:#34d399}
 .set input[type=checkbox]{accent-color:#34d399;width:13px;height:13px}
 .set .val{color:#6b7280;font-size:10px;width:28px;text-align:right}
 .m-bubble .bar,.m-bubble .set{display:none}
 .c{background:#1e2127;border:1px solid #2a2e37;border-radius:8px;padding:8px 10px;margin-bottom:6px;cursor:pointer}
 .c *{cursor:pointer}
 .c:hover{background:#242833;border-color:#3a4150}
 .c.on{border-color:#2f6f4f}
 .c.wait{border-color:#8a6d3b;background:#241f16}
 .top{display:flex;align-items:center;gap:6px}
 .dot{width:7px;height:7px;border-radius:50%;background:#4b5563;flex:none}
 .dot.live{background:#34d399;box-shadow:0 0 6px #34d399;animation:p 1.2s infinite}
 .dot.wait{background:#f0b866;box-shadow:0 0 6px #f0b866;animation:p 1.2s infinite}
 .w{color:#f0b866;font-size:11px;font-weight:700;margin-top:4px;
    overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
 .chk{color:#34d399;font:700 12px/1 ui-monospace;flex:none}
 .int{color:#f0b866;font:700 12px/1 ui-monospace;flex:none}
 .name{font-weight:700;color:#e5e7eb;font-size:12px}
 .ago{margin-left:auto;color:#6b7280;font-size:10px;flex:none}
 .br{color:#7c6f9e;font-size:10px}
 .meta{margin-top:4px;display:flex;gap:6px;align-items:center;font-size:10px}
 .mdl{color:#7f8794}
 .pm{padding:0 5px;border-radius:4px;background:#242833;color:#9ca3af}
 .pm.plan{background:#26304a;color:#93a7d8}
 .pm.auto{background:#3a2f1c;color:#e0b877}
 .pm.bypass{background:#3a1f22;color:#e08b8b}
 .t{color:#9ca3af;font-size:11px;margin-top:3px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
 .a{color:#5f6672;font-size:10px;margin-top:3px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
 .ag{font-size:11px;margin-top:3px;display:flex;gap:7px;align-items:baseline}
 .ag .m{flex:none}
 .ag .ty{flex:none;width:104px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
 .ag .de{flex:1;min-width:0;color:#8b929e;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
 .ag.run .ty{color:#f0b866}
 .ag.done .ty{color:#5aa079}
 .ag.run .m{color:#f0b866;animation:p 1s infinite}
 .ag.done .m{color:#5aa079}
 @keyframes p{50%{opacity:.25}}
 .empty{color:#4b5563;font-size:11px;padding:20px 8px;text-align:center}
 /* bubble = compact one-line-per-session summary */
 .bwrap{background:#1e2127;border:1px solid #2a2e37;border-radius:12px;padding:6px 9px;
    display:flex;flex-direction:column;gap:2px}
 .bwrap.hot{border-color:#8a6d3b;background:#231f17}
 .brow{display:flex;align-items:center;gap:7px;min-width:0}
 .bnm{flex:1;color:#cfd3da;font-size:11px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
 .bwt{color:#f0b866;font-size:10px;flex:none;max-width:110px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
 .bag{color:#6b7280;font-size:10px;flex:none}
 .bq{color:#5a6270;font-size:11px;text-align:center;padding:2px}
 .bmore{color:#6b7280;font-size:10px;padding-top:2px}
</style>
<div class=bar id=bar><span class=grip>⠿</span><span class=ttl>claudewatch</span>
 <button id=gear title="Settings">⚙</button>
 <span class=sp></span>
 <button class=mb data-m=bubble title="Minimize to bubble">◉</button>
 <button id=quit title="Quit">✕</button></div>
<div class=set id=set>
 <label class=row><span class=k>opacity</span><input id=op type=range min=20 max=100 step=5><span class=val id=opv></span></label>
 <label class=row><input type=checkbox data-k=autoExpand><span class=k>pop open when input needed</span></label>
 <label class=row><input type=checkbox data-k=hideIdle><span class=k>hide idle / finished sessions</span></label>
 <label class=row><input type=checkbox data-k=onTop><span class=k>float above all windows</span></label>
 <label class=row><input type=checkbox data-k=compact><span class=k>compact (hide activity & agents)</span></label>
</div>
<div id=x></div><script>
 var MODE='list',LAST=[],PW=0;
 var S={op:1,autoExpand:1,hideIdle:0,onTop:1,compact:0};   // user settings (persisted via Swift)
 function ago(s){return s<60?s+'s':s<3600?(s/60|0)+'m':(s/3600|0)+'h'}
 function esc(t){let d=document.createElement('div');d.textContent=t||'';return d.innerHTML}
 function focusit(tty){try{window.webkit.messageHandlers.focus.postMessage(tty)}catch(e){}}
 function post(){try{window.webkit.messageHandlers.cfg.postMessage(JSON.stringify({mode:MODE,pref:S}))}catch(e){}}
 function fit(){try{window.webkit.messageHandlers.cfg.postMessage(JSON.stringify({fit:document.body.scrollHeight}))}catch(e){}}
 // report the header's draggable gaps (bar minus buttons) so Swift can place drag handles there
 function dragLayout(){if(MODE!='list')return;
   var bar=document.getElementById('bar'),br=bar.getBoundingClientRect();
   var bs=[].map.call(bar.querySelectorAll('button'),function(b){var r=b.getBoundingClientRect();return[r.left,r.right]}).sort(function(a,b){return a[0]-b[0]});
   var gaps=[],cur=br.left;
   bs.forEach(function(b){if(b[0]-cur>4)gaps.push([cur,b[0]]);cur=Math.max(cur,b[1])});
   if(br.right-cur>4)gaps.push([cur,br.right]);
   var rects=gaps.map(function(g){return{x:g[0],y:br.top,w:g[1]-g[0],h:br.height}});
   try{window.webkit.messageHandlers.cfg.postMessage(JSON.stringify({drag:rects}))}catch(e){}}
 function syncUI(){
   [].forEach.call(document.querySelectorAll('.mb'),function(b){b.classList.toggle('act',b.dataset.m==MODE)});
   var op=document.getElementById('op');op.value=Math.round(S.op*100);document.getElementById('opv').textContent=op.value+'%';
   [].forEach.call(document.querySelectorAll('[data-k]'),function(c){c.checked=!!S[c.dataset.k]})}
 function setCfg(m,pref){MODE=m;if(pref)S=Object.assign({op:1,autoExpand:1,hideIdle:0,onTop:1,compact:0},pref);
   document.body.className='m-'+m;syncUI();render(LAST)}
 function setMode(m){setCfg(m,S);post()}
 // status marker, shared by list + bubble
 function mark(r){return r.state=='done'?'<span class=chk>✓</span>':
          r.state=='interrupted'?'<span class=int>⊘</span>':
          r.state=='waiting'?'<span class="dot wait"></span>':
          r.state=='working'?'<span class="dot live"></span>':'<span class=dot></span>'}
 function shModel(m){return (m||'').replace(/^claude-/,'').replace(/-\\d{6,}$/,'').replace('[1m]','')}
 function pmClass(p){return p=='plan'?'plan':(p=='acceptEdits'||p=='auto')?'auto':p=='bypassPermissions'?'bypass':''}
 function pmLabel(p){return p=='acceptEdits'?'auto-accept':p=='bypassPermissions'?'bypass':p=='default'?'default':p}
 function card(r){
   var cls=r.state=='waiting'?' wait':r.state=='working'?' on':'';
   var mdl=shModel(r.model),pm=r.mode;
   return '<div class="c'+cls+'" onclick="focusit(\\''+esc(r.tty)+'\\')">'+
     '<div class=top>'+mark(r)+'<span class=name>'+esc(r.name)+'</span>'+
     (r.branch?'<span class=br>'+esc(r.branch)+'</span>':'')+
     '<span class=ago>'+ago(r.ago)+'</span></div>'+
     (r.state=='waiting'?'<div class=w>▸ needs you · '+esc(r.wait||'input')+'</div>':'')+
     (r.title?'<div class=t>'+esc(r.title)+'</div>':'')+
     (!S.compact&&r.activity?'<div class=a>'+esc(r.activity)+'</div>':'')+
     ((mdl||pm)?'<div class=meta>'+
       (mdl?'<span class=mdl>'+esc(mdl)+'</span>':'')+
       (pm?'<span class="pm '+pmClass(pm)+'">'+esc(pmLabel(pm))+'</span>':'')+'</div>':'')+
     (S.compact?'':(r.agents||[]).map(function(a){return '<div class="ag '+(a.done?'done':'run')+'">'+
       '<span class=m>'+(a.done?'●':'○')+'</span>'+
       '<span class=ty>'+esc(a.type)+(a.bg?' ·bg':'')+'</span>'+
       '<span class=de>'+esc(a.desc)+'</span></div>'}).join(''))+
     '</div>'}
 function brow(r){return '<div class=brow>'+mark(r)+
   '<span class=bnm>'+esc(r.name)+'</span>'+
   (r.state=='waiting'?'<span class=bwt>'+esc(r.wait||'input')+'</span>':'')+
   '<span class=bag>'+ago(r.ago)+'</span></div>'}
 function render(rows){LAST=rows||[];var x=document.getElementById('x');
   var v=S.hideIdle?LAST.filter(function(r){return r.state=='working'||r.state=='waiting'}):LAST;
   var waitN=v.filter(function(r){return r.state=='waiting'}).length;
   if(S.autoExpand&&MODE=='bubble'&&waitN>PW){PW=waitN;setMode('list');return}   // rising edge → pop open
   PW=waitN;
   if(MODE=='bubble'){
     var inner=v.length?v.slice(0,8).map(brow).join('')+
       (v.length>8?'<div class=bmore>+'+(v.length-8)+' more</div>':'')
       :'<div class=bq>all quiet</div>';
     x.innerHTML='<div class="bwrap'+(waitN?' hot':'')+'">'+inner+'</div>';fit();return}
   if(!v.length){x.innerHTML='<div class=empty>'+(S.hideIdle?'nothing active':'no active sessions')+'</div>';fit();dragLayout();return}
   x.innerHTML=v.map(card).join('');fit();dragLayout()}
 document.getElementById('gear').onclick=function(){document.getElementById('set').classList.toggle('open');fit()};
 document.getElementById('quit').onclick=function(){try{window.webkit.messageHandlers.cfg.postMessage(JSON.stringify({quit:1}))}catch(e){}};
 [].forEach.call(document.querySelectorAll('.mb'),function(b){b.onclick=function(){setMode(b.dataset.m)}});
 document.getElementById('op').oninput=function(){S.op=this.value/100;document.getElementById('opv').textContent=this.value+'%';post()};
 [].forEach.call(document.querySelectorAll('[data-k]'),function(c){c.onchange=function(){S[c.dataset.k]=c.checked?1:0;post();render(LAST)}});
</script>
"""
