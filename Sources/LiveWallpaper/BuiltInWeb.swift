import Foundation

/// Self-contained HTML for the built-in web wallpaper — no external resources, so it renders with an
/// empty network allowlist and demonstrates the WebRenderer + its lockdown end to end.
enum BuiltInWeb {
    static let starfield = """
    <!doctype html><html><head><meta charset="utf-8"><style>
      html,body{margin:0;height:100%;background:#05060a;overflow:hidden}
      canvas{display:block}
    </style></head><body><canvas id="c"></canvas><script>
      const cv = document.getElementById('c'), ctx = cv.getContext('2d');
      let W, H, stars;
      function reset(){
        W = cv.width = innerWidth; H = cv.height = innerHeight;
        stars = Array.from({length: 600}, () => ({
          x:(Math.random()*2-1)*W, y:(Math.random()*2-1)*H, z:Math.random()*W
        }));
      }
      addEventListener('resize', reset); reset();
      function frame(){
        ctx.fillStyle = 'rgba(5,6,10,0.35)'; ctx.fillRect(0,0,W,H);
        ctx.fillStyle = '#dfe8ff';
        for (const s of stars){
          s.z -= 6;
          if (s.z <= 0){ s.z = W; s.x = (Math.random()*2-1)*W; s.y = (Math.random()*2-1)*H; }
          const k = 128 / s.z, px = s.x*k + W/2, py = s.y*k + H/2;
          if (px<0||px>=W||py<0||py>=H) continue;
          const r = (1 - s.z/W) * 2.4;
          ctx.beginPath(); ctx.arc(px, py, r, 0, 6.283); ctx.fill();
        }
        requestAnimationFrame(frame);
      }
      frame();
    </script></body></html>
    """
}
