  (function(){
    function wireCopy(btnId, srcId){
      var b=document.getElementById(btnId), s=document.getElementById(srcId);
      if(!b||!s) return;
      b.addEventListener('click',function(){
        navigator.clipboard.writeText(s.textContent.trim()).then(function(){
          var o=b.textContent; b.textContent='Copied ✓';
          setTimeout(function(){b.textContent=o;},1600);
        }).catch(function(){});
      });
    }
    wireCopy('copy','brew'); wireCopy('copy2','brew2'); wireCopy('vcopy','vcmd');

    // Single source of truth for the current version — bump this one line on release.
    var V="1.16.3";
    var dmg="https://github.com/NativeMojo/mojo-pulse/releases/download/v"+V+"/MojoPulse-"+V+".dmg";
    document.querySelectorAll("a.dl").forEach(function(a){ a.href=dmg; a.setAttribute("download",""); });
    ["dlver","ver","heroVer","reltag"].forEach(function(id){
      var el=document.getElementById(id); if(el) el.textContent="v"+V;
    });
    var y=document.getElementById('yr'); if(y) y.textContent=new Date().getFullYear();

    var reduced=window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    // Gentle reveal on scroll.
    if(!reduced && 'IntersectionObserver' in window){
      var io=new IntersectionObserver(function(es){
        es.forEach(function(e){ if(e.isIntersecting){ e.target.classList.add('in'); io.unobserve(e.target);} });
      },{rootMargin:'0px 0px -8% 0px'});
      document.querySelectorAll('.rv').forEach(function(el){ io.observe(el); });
    } else {
      document.querySelectorAll('.rv').forEach(function(el){ el.classList.add('in'); });
    }
    // Failsafe: never leave content hidden if the observer misbehaves.
    setTimeout(function(){
      document.querySelectorAll('.rv:not(.in)').forEach(function(el){ el.classList.add('in'); });
    }, 1600);

    // Videos: play only while visible; never autoplay under reduced motion.
    var vids=document.querySelectorAll('video');
    if(!reduced && 'IntersectionObserver' in window){
      var vio=new IntersectionObserver(function(es){
        es.forEach(function(e){
          var v=e.target;
          if(e.isIntersecting){ v.play().catch(function(){}); } else { v.pause(); }
        });
      },{threshold:.25});
      vids.forEach(function(v){ vio.observe(v); });
    } else {
      vids.forEach(function(v){ v.setAttribute('controls',''); });
    }

    // Lightbox: click any .zoom image to inspect it with a longer caption.
    var lb=document.getElementById('lb'), lbimg=document.getElementById('lbimg'),
        lbt=document.getElementById('lbt'), lbd=document.getElementById('lbd');
    function openLB(img){
      lbimg.src=img.currentSrc||img.src; lbimg.alt=img.alt||'';
      lbt.textContent=img.getAttribute('data-title')||img.alt||'';
      lbd.textContent=img.getAttribute('data-info')||'';
      lb.hidden=false; document.body.style.overflow='hidden';
    }
    function closeLB(){ lb.hidden=true; lbimg.src=''; document.body.style.overflow=''; }
    document.querySelectorAll('img.zoom').forEach(function(img){
      img.addEventListener('click',function(){ openLB(img); });
    });
    lb.addEventListener('click',function(e){ if(e.target!==lbt && e.target!==lbd) closeLB(); });
    document.addEventListener('keydown',function(e){ if(e.key==='Escape' && !lb.hidden) closeLB(); });
  })();
