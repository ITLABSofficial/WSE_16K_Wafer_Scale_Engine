#!/usr/bin/env python3
"""
FAST LAYOUT VIEWER & RENDERER (KLayout Engine)
==============================================
High-speed GDSII/OASIS mask layout inspector and renderer.
Reads layout hierarchies rapidly, renders layer-by-layer views,
and generates standalone interactive HTML outputs with 60 FPS pan/zoom.

Usage:
  python3 fast_layout_viewer.py --gds <layout.gds> --info
  python3 fast_layout_viewer.py --gds <layout.gds> --render <output.png> [--width 1920] [--height 1080]
  python3 fast_layout_viewer.py --gds <layout.gds> --html <output.html>
  python3 fast_layout_viewer.py --gds <layout.gds> --gui
"""

import sys
import os
import argparse
import time
import subprocess

try:
    import klayout.db as db
    import klayout.lay as lay
except ImportError:
    print("ERROR: 'klayout' Python package not found.")
    print("Install via: pip install klayout")
    sys.exit(1)


def get_layout_info(gds_path):
    t0 = time.time()
    layout = db.Layout()
    layout.read(gds_path)
    t1 = time.time()

    top = layout.top_cell()
    bbox = top.bbox()
    dbu = layout.dbu
    width_um = (bbox.right - bbox.left) * dbu
    height_um = (bbox.top - bbox.bottom) * dbu
    area_mm2 = (width_um * height_um) / 1e6

    layers = [(info.layer, info.datatype, info.name) for info in layout.layer_infos()]
    layers.sort()

    info = {
        "path": gds_path,
        "load_time_s": t1 - t0,
        "top_cell": top.name,
        "cell_count": layout.cells(),
        "layer_count": layout.layers(),
        "dbu": dbu,
        "bbox_um": (bbox.left * dbu, bbox.bottom * dbu, bbox.right * dbu, bbox.top * dbu),
        "width_um": width_um,
        "height_um": height_um,
        "area_mm2": area_mm2,
        "layers": layers
    }
    return info, layout


def print_info(info):
    print("=" * 65)
    print(f"  GDSII/OASIS LAYOUT REPORT: {os.path.basename(info['path'])}")
    print("=" * 65)
    print(f"  File Path      : {info['path']}")
    print(f"  Load Time      : {info['load_time_s']:.3f} seconds")
    print(f"  Top Cell       : {info['top_cell']}")
    print(f"  Total Cells    : {info['cell_count']}")
    print(f"  Layer Count    : {info['layer_count']}")
    print(f"  DBU (Grid)      : {info['dbu']:.6f} um")
    print(f"  Chip Width     : {info['width_um']:.2f} um ({info['width_um']/1000:.3f} mm)")
    print(f"  Chip Height    : {info['height_um']:.2f} um ({info['height_um']/1000:.3f} mm)")
    print(f"  Total Chip Area: {info['area_mm2']:.4f} mm²")
    print("-" * 65)
    print("  Detected Layers (First 20):")
    for l, d, name in info["layers"][:20]:
        n_str = f" ({name})" if name else ""
        print(f"    - Layer {l:3d} / Datatype {d:2d}{n_str}")
    if len(info["layers"]) > 20:
        print(f"    ... ve {len(info['layers']) - 20} ek katman.")
    print("=" * 65)


def render_image(gds_path, out_png, width=1920, height=1080, bbox=None, layers=None, hide_text=True):
    t0 = time.time()
    view = lay.LayoutView()
    view.load_layout(gds_path)
    view.max_hier()

    # Layer filtering and hiding LVS text/label layers
    iter = view.begin_layers()
    layer_list = [int(x.strip()) for x in layers.split(",") if x.strip().isdigit()] if layers else None

    while not iter.at_end():
        node = iter.current()
        # If hide_text is active and layer datatype is 251 (virtual LVS text), hide it
        if hide_text and ("/251" in node.source or "text" in node.name.lower()):
            node.visible = False
        elif layer_list and node.layer_index() not in layer_list:
            node.visible = False
        iter.next()

    # BBox zoom
    if bbox:
        x1, y1, x2, y2 = [float(v) for v in bbox.split(",")]
        dbu = view.cell_view(0).layout().dbu
        box = db.DBox(x1, y1, x2, y2)
        view.zoom_box(box)

    os.makedirs(os.path.dirname(os.path.abspath(out_png)), exist_ok=True)
    view.save_image(out_png, width, height)
    t1 = time.time()
    print(f"[SUCCESS] Rendered image ({width}x{height}): {out_png} (Time: {t1 - t0:.2f}s)")


def generate_interactive_html(gds_path, out_html, render_png=None):
    """
    Generates standalone HTML with smooth mouse Zoom & Pan,
    layer inspection details, and measurement ruler for local browser viewing.
    """
    if not render_png or not os.path.exists(render_png):
        temp_png = out_html.replace(".html", "_render.png")
        print(f"Generating high-resolution render for HTML: {temp_png} ...")
        render_image(gds_path, temp_png, width=3840, height=2160)
        render_png = temp_png

    info, _ = get_layout_info(gds_path)

    # HTML content (Smooth HTML5 Canvas Pan & Zoom + HUD)
    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>KLayout Fast Interactive Layout Viewer - {os.path.basename(gds_path)}</title>
  <style>
    * {{ margin: 0; padding: 0; box-sizing: border-box; }}
    body {{ background: #0c0f14; color: #e2e8f0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; overflow: hidden; width: 100vw; height: 100vh; }}
    #viewport {{ position: absolute; top: 0; left: 0; width: 100%; height: 100%; cursor: grab; }}
    #viewport:active {{ cursor: grabbing; }}
    canvas {{ display: block; }}
    .hud-panel {{ position: absolute; top: 16px; left: 16px; background: rgba(15, 23, 42, 0.85); backdrop-filter: blur(8px); border: 1px solid #334155; border-radius: 8px; padding: 16px; min-width: 300px; box-shadow: 0 10px 25px rgba(0,0,0,0.5); pointer-events: none; }}
    .hud-title {{ font-size: 16px; font-weight: 700; color: #38bdf8; margin-bottom: 8px; display: flex; align-items: center; justify-content: space-between; }}
    .hud-badge {{ background: #0284c7; color: white; font-size: 10px; padding: 2px 6px; border-radius: 4px; font-weight: 600; text-transform: uppercase; }}
    .hud-item {{ font-size: 12px; margin: 4px 0; color: #94a3b8; display: flex; justify-content: space-between; }}
    .hud-item span.val {{ color: #f1f5f9; font-weight: 600; font-family: monospace; }}
    .controls-hint {{ position: absolute; bottom: 16px; left: 16px; background: rgba(15, 23, 42, 0.75); border: 1px solid #1e293b; padding: 8px 12px; border-radius: 6px; font-size: 11px; color: #64748b; pointer-events: none; }}
    .btn-bar {{ position: absolute; top: 16px; right: 16px; display: flex; gap: 8px; }}
    .action-btn {{ background: #1e293b; color: #38bdf8; border: 1px solid #38bdf8; padding: 8px 14px; border-radius: 6px; font-size: 12px; font-weight: 600; cursor: pointer; transition: 0.15s; }}
    .action-btn:hover {{ background: #0284c7; color: #ffffff; }}
  </style>
</head>
<body>
  <div id="viewport">
    <canvas id="layoutCanvas"></canvas>
  </div>

  <div class="hud-panel">
    <div class="hud-title">
      <span>{info['top_cell']}</span>
      <span class="hud-badge">GDSII Mask</span>
    </div>
    <div class="hud-item"><span>File:</span> <span class="val">{os.path.basename(info['path'])}</span></div>
    <div class="hud-item"><span>Chip Dimensions:</span> <span class="val">{info['width_um']:.1f} × {info['height_um']:.1f} µm</span></div>
    <div class="hud-item"><span>Die Area:</span> <span class="val">{info['area_mm2']:.3f} mm²</span></div>
    <div class="hud-item"><span>Cell Count:</span> <span class="val">{info['cell_count']}</span></div>
    <div class="hud-item"><span>Layerlar:</span> <span class="val">{info['layer_count']} Layer</span></div>
    <div class="hud-item"><span>DBU Resolution:</span> <span class="val">{info['dbu'] * 1000:.0f} nm</span></div>
    <div class="hud-item" style="margin-top: 8px; border-top: 1px solid #334155; padding-top: 6px;">
      <span>Zoom:</span> <span class="val" id="zoomLevel">100%</span>
    </div>
  </div>

  <div class="btn-bar">
    <button class="action-btn" onclick="resetView()">Reset (Center)</button>
    <button class="action-btn" onclick="zoomIn()">Zoom +</button>
    <button class="action-btn" onclick="zoomOut()">Zoom -</button>
  </div>

  <div class="controls-hint">
    [Left-Click + Drag]: Pan | [Wheel]: Smooth Zoom | [Double-Click]: 1:1 Reset
  </div>

  <script>
    const canvas = document.getElementById('layoutCanvas');
    const ctx = canvas.getContext('2d');
    const zoomText = document.getElementById('zoomLevel');

    const img = new Image();
    img.src = "{os.path.basename(render_png)}";

    let scale = 1;
    let originX = 0;
    let originY = 0;
    let isDragging = false;
    let startX = 0, startY = 0;

    function resize() {{
      canvas.width = window.innerWidth;
      canvas.height = window.innerHeight;
      draw();
    }}
    window.addEventListener('resize', resize);

    img.onload = () => {{
      resize();
      resetView();
    }};

    function resetView() {{
      const scaleX = (canvas.width * 0.9) / img.width;
      const scaleY = (canvas.height * 0.9) / img.height;
      scale = Math.min(scaleX, scaleY);
      originX = (canvas.width - img.width * scale) / 2;
      originY = (canvas.height - img.height * scale) / 2;
      draw();
    }}

    function draw() {{
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.imageSmoothingEnabled = scale < 1.5;
      ctx.drawImage(img, originX, originY, img.width * scale, img.height * scale);
      zoomText.textContent = Math.round(scale * 100) + '%';
    }}

    canvas.addEventListener('mousedown', (e) => {{
      isDragging = true;
      startX = e.clientX - originX;
      startY = e.clientY - originY;
    }});

    window.addEventListener('mouseup', () => {{ isDragging = false; }});
    window.addEventListener('mousemove', (e) => {{
      if (!isDragging) return;
      originX = e.clientX - startX;
      originY = e.clientY - startY;
      draw();
    }});

    canvas.addEventListener('wheel', (e) => {{
      e.preventDefault();
      const zoomFactor = e.deltaY < 0 ? 1.15 : 0.85;
      const mouseX = e.clientX;
      const mouseY = e.clientY;

      const newScale = scale * zoomFactor;
      if (newScale < 0.05 || newScale > 50) return;

      originX = mouseX - (mouseX - originX) * zoomFactor;
      originY = mouseY - (mouseY - originY) * zoomFactor;
      scale = newScale;
      draw();
    }}, {{ passive: false }});

    canvas.addEventListener('dblclick', (e) => {{
      scale = 1.0;
      originX = (canvas.width - img.width) / 2;
      originY = (canvas.height - img.height) / 2;
      draw();
    }});

    function zoomIn() {{
      scale *= 1.25;
      draw();
    }}
    function zoomOut() {{
      scale *= 0.8;
      draw();
    }}
  </script>
</body>
</html>
"""
    with open(out_html, "w", encoding="utf-8") as f:
        f.write(html_content)
    print(f"[SUCCESS] Interactive browser viewer created: {out_html}")


def launch_gui(gds_path):
    print(f"Launching KLayout GUI: {gds_path} ...")
    subprocess.Popen(["klayout", gds_path])


def main():
    parser = argparse.ArgumentParser(description="KLayout Fast Mask and Layout Viewer Tool")
    parser.add_argument("--gds", required=True, help="Path to GDSII or OASIS file")
    parser.add_argument("--info", action="store_true", help="Report chip dimensions, cell and layer counts")
    parser.add_argument("--render", help="Output image path (e.g. render.png)")
    parser.add_argument("--width", type=int, default=1920, help="Image width in pixels (default: 1920)")
    parser.add_argument("--height", type=int, default=1080, help="Image height in pixels (default: 1080)")
    parser.add_argument("--bbox", help="Zoom bounding box 'x1,y1,x2,y2' in um")
    parser.add_argument("--layers", help="Render only specific layers (e.g. '64,65,66')")
    parser.add_argument("--html", help="Generate standalone interactive HTML pan/zoom viewer")
    parser.add_argument("--gui", action="store_true", help="Launch KLayout GUI directly")

    parser.add_argument("--show-text", action="store_true", help="Show LVS text and label layers (default: hidden)")
    args = parser.parse_args()

    hide_text = not args.show_text

    if not os.path.exists(args.gds):
        print(f"ERROR: File not found: {args.gds}")
        sys.exit(1)

    if args.info:
        info, _ = get_layout_info(args.gds)
        print_info(info)

    if args.render:
        render_image(args.gds, args.render, args.width, args.height, args.bbox, args.layers, hide_text)

    if args.html:
        render_png = args.render if args.render else None
        generate_interactive_html(args.gds, args.html, render_png)

    if args.gui:
        launch_gui(args.gds)

    if not (args.info or args.render or args.html or args.gui):
        # Default: Display layout info and perform fast 1080p render
        info, _ = get_layout_info(args.gds)
        print_info(info)


if __name__ == "__main__":
    main()
