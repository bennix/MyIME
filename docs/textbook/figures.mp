prologues := 3;
outputtemplate := "%j-%c.mps";

u := 1cm;
pickup pencircle scaled .8pt;
color blue, cyan, green, orange, gray, lightblue, lightgreen, lightorange;
blue := (0.09,0.36,0.83); cyan := (0.05,0.45,0.56);
green := (0.09,0.50,0.23); orange := (0.71,0.28,0.03);
gray := (0.40,0.43,0.48);
lightblue := .88white + .12blue;
lightgreen := .88white + .12green;
lightorange := .88white + .12orange;

vardef boxit(expr p, w, h, c) =
  fill unitsquare xscaled w yscaled h shifted (p-(w/2,h/2)) withcolor c;
  draw unitsquare xscaled w yscaled h shifted (p-(w/2,h/2)) withcolor .65c;
enddef;

vardef arrow(expr a,b,c) =
  drawarrow a--b withpen pencircle scaled 1.1pt withcolor c;
enddef;

% 1. End-to-end IME pipeline.
beginfig(1);
  pair p[];
  for i=0 upto 6: p[i] := (i*2.6u,0); endfor
  for i=0 upto 6:
    boxit(p[i],2.05u,1.05u, if i mod 3=0: lightblue elseif i mod 3=1: lightgreen else: lightorange fi);
  endfor
  label(btex Keyboard etex,p[0]); label(btex IMK etex,p[1]);
  label(btex Preedit etex,p[2]); label(btex Segment etex,p[3]);
  label(btex Lookup etex,p[4]); label(btex Rank etex,p[5]);
  label(btex Commit etex,p[6]);
  for i=0 upto 5: arrow(p[i]+(1.05u,0),p[i+1]-(1.05u,0),blue); endfor
endfig;

% 2. Composition state machine.
beginfig(2);
  pair idle, composing, selecting, committed, cancelled;
  idle=(0,0); composing=(5u,0); selecting=(10u,0);
  committed=(10u,-3u); cancelled=(5u,-3u);
  boxit(idle,2.7u,1.1u,lightblue); label(btex Idle etex,idle);
  boxit(composing,3.1u,1.1u,lightgreen); label(btex Composing etex,composing);
  boxit(selecting,2.9u,1.1u,lightorange); label(btex Selecting etex,selecting);
  boxit(committed,2.9u,1.1u,lightblue); label(btex Commit etex,committed);
  boxit(cancelled,2.9u,1.1u,.92white+.08red); label(btex Cancel etex,cancelled);
  arrow(idle+(1.35u,0),composing-(1.55u,0),blue);
  arrow(composing+(1.55u,0),selecting-(1.45u,0),blue);
  arrow(selecting+(0,-.55u),committed+(0,.55u),green);
  arrow(composing+(0,-.55u),cancelled+(0,.55u),orange);
  arrow(committed+(-1.45u,0),idle+(0,-.55u),gray);
  arrow(cancelled+(-1.45u,0),idle+(0,-.55u),gray);
  label.top(btex letters etex,(2.5u,.15u));
  label.top(btex arrows / digits etex,(7.5u,.15u));
endfig;

% 3. Controller-engine separation.
beginfig(3);
  pair app, controller, protocol, engine, store, tests;
  app=(0,2u); controller=(4u,2u); protocol=(8u,2u);
  engine=(12u,2u); store=(16u,2u); tests=(8u,-1u);
  boxit(app,2.6u,1.1u,lightblue); label(btex Client etex,app);
  boxit(controller,3.2u,1.1u,lightorange); label(btex Controller etex,controller);
  boxit(protocol,2.8u,1.1u,lightgreen); label(btex IMEEngine etex,protocol);
  boxit(engine,2.8u,1.1u,lightblue); label(btex Engine etex,engine);
  boxit(store,2.8u,1.1u,lightgreen); label(btex Store etex,store);
  boxit(tests,3.2u,1.1u,lightorange); label(btex MemoryStore etex,tests);
  arrow(app+(1.3u,0),controller-(1.6u,0),blue);
  arrow(controller+(1.6u,0),protocol-(1.4u,0),blue);
  arrow(protocol+(1.4u,0),engine-(1.4u,0),blue);
  arrow(engine+(1.4u,0),store-(1.4u,0),blue);
  arrow(tests+(0,.55u),protocol+(0,-.55u),green);
endfig;

% 4. Pinyin segmentation DAG for xian.
beginfig(4);
  pair p[]; for i=0 upto 4: p[i]=(i*3u,0); endfor
  for i=0 upto 4: fill fullcircle scaled .28u shifted p[i] withcolor blue; endfor
  drawarrow p[0]..(1.5u,1.6u)..p[2] withcolor green;
  drawarrow p[2]..(4.5u,1.6u)..p[3] withcolor green;
  drawarrow p[0]..(6u,2.8u)..p[4] withcolor blue;
  drawarrow p[0]..(1.5u,-1.5u)..p[1] withcolor orange;
  drawarrow p[1]..(7.5u,-1.8u)..p[4] withcolor orange;
  label.top(btex xi etex,(3u,1.25u)); label.top(btex an etex,(7.5u,1.25u));
  label.top(btex xian etex,(6u,2.3u));
  label.bot(btex x etex,(1.5u,-1.1u)); label.bot(btex ian etex,(7u,-1.3u));
  for i=0 upto 4: label.bot(decimal i,p[i]-(0,.2u)); endfor
endfig;

% 5. Word lattice.
beginfig(5);
  pair p[]; for i=0 upto 5: p[i]=(i*2.8u,0); endfor
  for i=0 upto 5: fill fullcircle scaled .25u shifted p[i] withcolor blue; endfor
  drawarrow p[0]..(1.4u,1.7u)..p[2] withcolor green; label.top(btex $w_1$ etex,(1.4u,1.25u));
  drawarrow p[2]..(4.2u,1.7u)..p[3] withcolor green; label.top(btex $w_2$ etex,(7u,1.2u));
  drawarrow p[3]..(5.6u,1.7u)..p[5] withcolor green; label.top(btex $w_3$ etex,(11.2u,1.25u));
  drawarrow p[0]..(7u,3u)..p[5] withcolor blue; label.top(btex $w_{1:5}$ etex,(7u,2.45u));
  drawarrow p[0]..(1.4u,-1.6u)..p[1] withcolor orange;
  drawarrow p[1]..(4.2u,-1.6u)..p[3] withcolor orange;
  drawarrow p[3]..(5.6u,-1.6u)..p[5] withcolor orange;
  for i=0 upto 5: label.bot(decimal i,p[i]-(0,.2u)); endfor
endfig;

% 6. Ranking score components.
beginfig(6);
  pair c, p[]; c=(8u,0);
  boxit(c,4u,1.35u,lightblue); label(btex $S(c)$ etex,c);
  p[0]=(0,3u); p[1]=(0,1u); p[2]=(0,-1u); p[3]=(0,-3u);
  for i=0 upto 3:
    boxit(p[i],3.4u,1.05u, if i<2: lightgreen else: lightorange fi);
    arrow(p[i]+(1.7u,0),c-(2u,0)+(0,(1.5-i)*.25u),if i<2: green else: orange fi);
  endfor
  label(btex Frequency etex,p[0]); label(btex Context etex,p[1]);
  label(btex Fuzzy cost etex,p[2]); label(btex Partial cost etex,p[3]);
endfig;

% 7. Two-store architecture.
beginfig(7);
  pair engine, system, user, model;
  engine=(7u,2u); system=(1u,-1u); user=(7u,-1u); model=(13u,-1u);
  boxit(engine,4u,1.3u,lightblue); label(btex Engine etex,engine);
  boxit(system,3.6u,1.2u,lightgreen); label(btex System DB etex,system);
  boxit(user,3.6u,1.2u,lightorange); label(btex User DB etex,user);
  boxit(model,3.6u,1.2u,lightgreen); label(btex Language Model etex,model);
  arrow(system+(0,.6u),engine+(-1.5u,-.65u),green);
  arrow(user+(0,.6u),engine+(0,-.65u),orange);
  arrow(model+(0,.6u),engine+(1.5u,-.65u),green);
endfig;

% 8. Learning feedback loop.
beginfig(8);
  pair type, rank, choose, learn;
  type=(0,0); rank=(4u,2.5u); choose=(8u,0); learn=(4u,-2.5u);
  boxit(type,2.7u,1.1u,lightblue); label(btex Type etex,type);
  boxit(rank,2.7u,1.1u,lightgreen); label(btex Rank etex,rank);
  boxit(choose,2.7u,1.1u,lightorange); label(btex Select etex,choose);
  boxit(learn,2.7u,1.1u,lightblue); label(btex Learn etex,learn);
  drawarrow type+(1.2u,.45u)..(2u,2u)..rank-(1.2u,.45u) withcolor blue;
  drawarrow rank+(1.2u,-.45u)..(6u,2u)..choose-(1.2u,.45u) withcolor green;
  drawarrow choose+(-1.2u,-.45u)..(6u,-2u)..learn+(1.2u,.45u) withcolor orange;
  drawarrow learn+(-1.2u,.45u)..(2u,-2u)..type+(1.2u,-.45u) withcolor blue;
endfig;

% 9. Candidate window coordinates.
beginfig(9);
  pair caret, window, screen;
  screen=(7u,2u); boxit(screen,14u,7u,.97white);
  caret=(4u,1u); draw caret--caret+(0,1u) withpen pencircle scaled 1.8pt withcolor blue;
  window=(7u,-.2u); boxit(window,7u,1.6u,lightblue); label(btex Candidates etex,window);
  drawarrow caret+(0,.3u)--window+(-3.5u,.3u) withcolor orange;
  label.top(btex Caret etex,caret+(0,1u));
  draw (0,5.5u)--(14u,5.5u) withcolor gray;
  draw (0,-1.5u)--(14u,-1.5u) withcolor gray;
endfig;

% 10. Input source lifecycle.
beginfig(10);
  pair dmg, installed, registered, selected, server;
  dmg=(0,0); installed=(3.6u,0); registered=(7.2u,0); selected=(10.8u,0); server=(14.4u,0);
  for p=dmg,installed,registered,selected,server: boxit(p,2.8u,1.1u,lightblue); endfor
  label(btex DMG etex,dmg); label(btex Installed etex,installed);
  label(btex Registered etex,registered); label(btex Selected etex,selected);
  label(btex IMKServer etex,server);
  arrow(dmg+(1.4u,0),installed-(1.4u,0),blue);
  arrow(installed+(1.4u,0),registered-(1.4u,0),blue);
  arrow(registered+(1.4u,0),selected-(1.4u,0),blue);
  arrow(selected+(1.4u,0),server-(1.4u,0),blue);
endfig;

% 11. Test pyramid.
beginfig(11);
  path a,b,c;
  a=(-7u,-3u)--(7u,-3u)--(5u,-.8u)--(-5u,-.8u)--cycle;
  b=(-5u,-.5u)--(5u,-.5u)--(3u,1.7u)--(-3u,1.7u)--cycle;
  c=(-3u,2u)--(3u,2u)--(0,4.5u)--cycle;
  fill a withcolor lightgreen; draw a withcolor green;
  fill b withcolor lightblue; draw b withcolor blue;
  fill c withcolor lightorange; draw c withcolor orange;
  label(btex Engine tests etex,(0,-1.9u));
  label(btex Integration tests etex,(0,.6u));
  label(btex App trials etex,(0,2.8u));
endfig;

% 12. Release gate.
beginfig(12);
  pair p[]; for i=0 upto 5: p[i]=(i*3u,0); endfor
  for i=0 upto 5: boxit(p[i],2.35u,1.05u,if i=5: lightgreen else: lightblue fi); endfor
  label(btex Test etex,p[0]); label(btex Build etex,p[1]); label(btex Sign etex,p[2]);
  label(btex Notarize etex,p[3]); label(btex Staple etex,p[4]); label(btex DMG etex,p[5]);
  for i=0 upto 4: arrow(p[i]+(1.18u,0),p[i+1]-(1.18u,0),blue); endfor
endfig;

% 13. Teaching roadmap.
beginfig(13);
  pair p[]; for i=0 upto 7: p[i]=(i*2.25u,0); endfor
  draw p[0]--p[7] withpen pencircle scaled 2pt withcolor gray;
  for i=0 upto 7:
    fill fullcircle scaled .48u shifted p[i] withcolor if i<3: blue elseif i<6: green else: orange fi;
    label.bot(decimal(i+1),p[i]-(0,.35u));
  endfor
  label.top(btex Echo etex,p[0]); label.top(btex Preedit etex,p[1]);
  label.top(btex Lookup etex,p[2]); label.top(btex Segment etex,p[3]);
  label.top(btex Rank etex,p[4]); label.top(btex Learn etex,p[5]);
  label.top(btex Integrate etex,p[6]); label.top(btex Ship etex,p[7]);
endfig;

% 14. MyIME thread model: MainActor and serialized user-store writes.
beginfig(14);
  pair e, c, ui, q, db, lock;
  draw (-1u,1.2u)--(17u,1.2u) withpen pencircle scaled 1pt withcolor gray;
  label.lft(btex MainActor etex,(-.4u,3.2u));
  label.lft(btex UserStore queue etex,(-.4u,-1.2u));
  e=(2u,3.2u); c=(7u,3.2u); ui=(12u,3.2u);
  q=(7u,-1.2u); db=(12u,-1.2u); lock=(7u,.25u);
  boxit(e,3.2u,1.1u,lightblue); label(btex IMK callback etex,e);
  boxit(c,3.2u,1.1u,lightgreen); label(btex Engine snapshot etex,c);
  boxit(ui,3.2u,1.1u,lightorange); label(btex Candidate UI etex,ui);
  boxit(q,3.5u,1.1u,lightblue); label(btex async learn etex,q);
  boxit(db,3.5u,1.1u,lightgreen); label(btex SQLite write etex,db);
  boxit(lock,2.3u,.8u,lightorange); label(btex NSLock etex,lock);
  arrow(e+(1.6u,0),c-(1.6u,0),blue);
  arrow(c+(1.6u,0),ui-(1.6u,0),blue);
  drawarrow c+(0,-.55u)..(8u,1.3u)..q+(0,.55u) withcolor green;
  arrow(q+(1.75u,0),db-(1.75u,0),green);
  drawarrow lock+(0,.4u)--c+(0,-.55u) withcolor orange;
  label.top(btex immutable value etex,(9.5u,3.45u));
  label.bot(btex no AppKit etex,(9.5u,-1.55u));
endfig;

% 15. AppKit screen coordinates and candidate panel placement.
beginfig(15);
  pair O, caret, panel, topRight;
  O=(0,0); topRight=(15u,8u);
  fill unitsquare xscaled 15u yscaled 8u withcolor .97white;
  draw O--(15u,0)--topRight--(0,8u)--cycle withpen pencircle scaled 1.1pt withcolor gray;
  arrow(O,(2u,0),blue); arrow(O,(0,2u),blue);
  label.bot(btex $x$ etex,(2u,0)); label.lft(btex $y$ etex,(0,2u)); label.llft(btex $O_s$ etex,O);
  caret=(8u,5u);
  draw (7.9u,4.8u)--(7.9u,5.8u) withpen pencircle scaled 2pt withcolor orange;
  draw unitsquare xscaled 1.5u yscaled .8u shifted (caret-(.75u,0)) dashed evenly withcolor orange;
  label.top(btex lineHeightRectangle etex,(8u,5.9u));
  panel=(8u,3.3u);
  boxit(panel,6u,1.15u,lightblue); label(btex NSPanel etex,panel);
  drawarrow caret-(0,.1u)--panel+(0,.575u) withcolor green;
  label.rt(btex $g$ etex,(8u,4.25u));
  draw (0,1u)--(15u,1u) dashed evenly withcolor gray;
  label.lrt(btex visibleFrame.minY etex,(.2u,1u));
  label.bot(btex global screen coordinates; secondary screens may use negative origins etex,(7.5u,-.6u));
endfig;

% 16. Beam search expansion with beam width two.
beginfig(16);
  pair s, a,b,c,d,e,f,g;
  s=(0,0); a=(4u,2u); b=(4u,0); c=(4u,-2u);
  d=(8u,2.5u); e=(8u,.8u); f=(8u,-.9u); g=(8u,-2.6u);
  fill fullcircle scaled .42u shifted s withcolor blue; label.lft(btex start etex,s);
  for p=a,b,c,d,e,f,g: fill fullcircle scaled .42u shifted p withcolor blue; endfor
  drawarrow s--a withcolor green; drawarrow s--b withcolor green; drawarrow s--c dashed evenly withcolor gray;
  label.rt(btex $A:-1.2$ etex,a); label.rt(btex $B:-1.7$ etex,b); label.rt(btex $C:-2.9$ etex,c);
  drawarrow a--d withcolor green; drawarrow a--e withcolor green;
  drawarrow b--f withcolor green; drawarrow b--g withcolor green;
  label.rt(btex $AD:-2.0$ etex,d); label.rt(btex $AE:-2.4$ etex,e);
  label.rt(btex $BF:-2.2$ etex,f); label.rt(btex $BG:-3.1$ etex,g);
  draw fullcircle scaled .8u shifted c withcolor orange;
  draw fullcircle scaled .8u shifted g withcolor orange;
  label.top(btex Step 0 etex,(0,3.4u));
  label.top(btex Step 1: keep top 2 etex,(4u,3.4u));
  label.top(btex Step 2: expand and prune etex,(8u,3.4u));
  boxit((14u,.8u),5.2u,2.8u,lightblue);
  label(btex $B=2$ etex,(14u,1.7u));
  label(btex keep: $AD, BF$ etex,(14u,.8u));
  label(btex prune: $AE, BG$ etex,(14u,-.1u));
  arrow((10u,.8u),(11.4u,.8u),blue);
endfig;

end
