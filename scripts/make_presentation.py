"""
make_presentation.py
Generates a PowerPoint presentation for the KCF mid-semester demo.

Prerequisites:
  pip install python-pptx
  python scripts/kcf_real_image.py data/Test_image1.png --row 240 --col 300 --presentation

Usage:
  python scripts/make_presentation.py

Output:
  docs/KCF_MidSemester_Presentation.pptx
"""

from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
import os

# ── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.join(SCRIPT_DIR, '..')
FIG_DIR = os.path.join(ROOT_DIR, 'docs', 'MidTerm Report')
EQ_DIR = os.path.join(FIG_DIR, 'equations')
OUT_PATH = os.path.join(ROOT_DIR, 'docs', 'KCF_MidSemester_Presentation.pptx')

# ── Colours ──────────────────────────────────────────────────────────────────
BG_COLOR = RGBColor(0x1a, 0x1a, 0x2e)
TITLE_COLOR = RGBColor(0x00, 0xd4, 0xaa)
WHITE = RGBColor(0xff, 0xff, 0xff)
LIGHT_GRAY = RGBColor(0xbb, 0xbb, 0xbb)
RED = RGBColor(0xff, 0x44, 0x44)
BLUE = RGBColor(0x44, 0x88, 0xff)
GREEN = RGBColor(0x00, 0xff, 0x66)
YELLOW = RGBColor(0xff, 0xdd, 0x44)

# ── Slide dimensions (16:9) ──────────────────────────────────────────────────
SLIDE_W = Inches(13.333)
SLIDE_H = Inches(7.5)


def fig(name):
    """Return full path to a figure file."""
    return os.path.join(FIG_DIR, name)


def eq(name):
    """Return full path to an equation image."""
    return os.path.join(EQ_DIR, name)


def set_bg(slide, color=BG_COLOR):
    """Set slide background to solid colour."""
    bg = slide.background
    fill = bg.fill
    fill.solid()
    fill.fore_color.rgb = color


def add_textbox(slide, left, top, width, height, text, font_size=20,
                color=WHITE, bold=False, alignment=PP_ALIGN.LEFT):
    """Add a simple text box to the slide."""
    txBox = slide.shapes.add_textbox(left, top, width, height)
    tf = txBox.text_frame
    tf.word_wrap = True
    p = tf.paragraphs[0]
    p.text = text
    p.font.size = Pt(font_size)
    p.font.color.rgb = color
    p.font.bold = bold
    p.alignment = alignment
    return txBox


def add_bullet_slide(prs, title_text, bullets, image_path=None, sub_text=None):
    """Create a slide with title, bullet points, and optional image on the right."""
    slide = prs.slides.add_slide(prs.slide_layouts[6])  # blank
    set_bg(slide)

    # Title
    add_textbox(slide, Inches(0.6), Inches(0.3), Inches(12), Inches(0.8),
                title_text, font_size=32, color=TITLE_COLOR, bold=True)

    # Underline bar
    from pptx.shapes.autoshape import Shape
    shape = slide.shapes.add_shape(
        1, Inches(0.6), Inches(1.05), Inches(11.5), Pt(3))  # 1 = rectangle
    shape.fill.solid()
    shape.fill.fore_color.rgb = TITLE_COLOR
    shape.line.fill.background()

    # Determine text area width based on image presence
    text_w = Inches(6.5) if image_path else Inches(11.5)
    text_left = Inches(0.6)
    top = Inches(1.3)

    # Bullets
    txBox = slide.shapes.add_textbox(text_left, top, text_w, Inches(5.5))
    tf = txBox.text_frame
    tf.word_wrap = True
    for i, bullet in enumerate(bullets):
        if i == 0:
            p = tf.paragraphs[0]
        else:
            p = tf.add_paragraph()
        p.text = bullet
        p.font.size = Pt(20)
        p.font.color.rgb = WHITE
        p.space_after = Pt(10)
        p.level = 0

    # Sub-text (e.g., equation caption)
    if sub_text:
        p = tf.add_paragraph()
        p.text = sub_text
        p.font.size = Pt(16)
        p.font.color.rgb = LIGHT_GRAY
        p.font.italic = True
        p.space_before = Pt(14)

    # Image on right side
    if image_path and os.path.exists(image_path):
        img_left = Inches(7.3)
        img_top = Inches(1.3)
        img_w = Inches(5.5)
        slide.shapes.add_picture(image_path, img_left, img_top, width=img_w)

    return slide


def add_image_slide(prs, title_text, image_path, caption=None):
    """Create a slide with a large centred image."""
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    set_bg(slide)

    add_textbox(slide, Inches(0.6), Inches(0.2), Inches(12), Inches(0.7),
                title_text, font_size=30, color=TITLE_COLOR, bold=True)

    if os.path.exists(image_path):
        slide.shapes.add_picture(image_path, Inches(0.8), Inches(1.1),
                                 width=Inches(11.5))

    if caption:
        add_textbox(slide, Inches(0.6), Inches(6.8), Inches(12), Inches(0.6),
                    caption, font_size=16, color=LIGHT_GRAY,
                    alignment=PP_ALIGN.CENTER)

    return slide


def add_two_image_slide(prs, title_text, img1_path, img2_path, cap1='', cap2=''):
    """Slide with two images side by side."""
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    set_bg(slide)

    add_textbox(slide, Inches(0.6), Inches(0.2), Inches(12), Inches(0.7),
                title_text, font_size=30, color=TITLE_COLOR, bold=True)

    if os.path.exists(img1_path):
        slide.shapes.add_picture(img1_path, Inches(0.4), Inches(1.2), width=Inches(6.0))
    if os.path.exists(img2_path):
        slide.shapes.add_picture(img2_path, Inches(6.8), Inches(1.2), width=Inches(6.0))

    if cap1:
        add_textbox(slide, Inches(0.4), Inches(6.7), Inches(6), Inches(0.5),
                    cap1, font_size=14, color=LIGHT_GRAY, alignment=PP_ALIGN.CENTER)
    if cap2:
        add_textbox(slide, Inches(6.8), Inches(6.7), Inches(6), Inches(0.5),
                    cap2, font_size=14, color=LIGHT_GRAY, alignment=PP_ALIGN.CENTER)

    return slide


def add_table_slide(prs, title_text, headers, rows, col_widths=None):
    """Create a slide with a styled table."""
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    set_bg(slide)

    add_textbox(slide, Inches(0.6), Inches(0.3), Inches(12), Inches(0.7),
                title_text, font_size=32, color=TITLE_COLOR, bold=True)

    n_rows = len(rows) + 1
    n_cols = len(headers)
    tbl_left = Inches(0.8)
    tbl_top = Inches(1.4)
    tbl_w = Inches(11.5)
    tbl_h = Inches(0.5) * n_rows

    table_shape = slide.shapes.add_table(n_rows, n_cols, tbl_left, tbl_top, tbl_w, tbl_h)
    table = table_shape.table

    # Header row
    for j, h in enumerate(headers):
        cell = table.cell(0, j)
        cell.text = h
        for p in cell.text_frame.paragraphs:
            p.font.size = Pt(18)
            p.font.bold = True
            p.font.color.rgb = RGBColor(0x1a, 0x1a, 0x2e)
            p.alignment = PP_ALIGN.CENTER
        cell.fill.solid()
        cell.fill.fore_color.rgb = TITLE_COLOR

    # Data rows
    for i, row in enumerate(rows):
        for j, val in enumerate(row):
            cell = table.cell(i + 1, j)
            cell.text = val
            for p in cell.text_frame.paragraphs:
                p.font.size = Pt(16)
                p.font.color.rgb = WHITE
                p.alignment = PP_ALIGN.CENTER
            cell.fill.solid()
            cell.fill.fore_color.rgb = RGBColor(0x2a, 0x2a, 0x45) if i % 2 == 0 else RGBColor(0x22, 0x22, 0x3a)

    return slide


def add_equation_bullet_slide(prs, title_text, eq_path, bullets):
    """Slide with equation image on top and bullets below."""
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    set_bg(slide)

    add_textbox(slide, Inches(0.6), Inches(0.3), Inches(12), Inches(0.7),
                title_text, font_size=32, color=TITLE_COLOR, bold=True)

    # Equation image centred
    if os.path.exists(eq_path):
        slide.shapes.add_picture(eq_path, Inches(2.5), Inches(1.2), width=Inches(8))

    # Bullets below
    txBox = slide.shapes.add_textbox(Inches(0.8), Inches(3.0), Inches(11.5), Inches(4.0))
    tf = txBox.text_frame
    tf.word_wrap = True
    for i, bullet in enumerate(bullets):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.text = bullet
        p.font.size = Pt(20)
        p.font.color.rgb = WHITE
        p.space_after = Pt(8)

    return slide


# ══════════════════════════════════════════════════════════════════════════════
# SLIDE BUILDERS
# ══════════════════════════════════════════════════════════════════════════════

def build_title_slide(prs):
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    set_bg(slide)

    add_textbox(slide, Inches(1), Inches(1.5), Inches(11), Inches(1.2),
                'RTL Design of a KCF Visual Tracker',
                font_size=44, color=TITLE_COLOR, bold=True,
                alignment=PP_ALIGN.CENTER)

    add_textbox(slide, Inches(1), Inches(3.0), Inches(11), Inches(0.6),
                'ECE499 Major Project — Mid-Semester Presentation',
                font_size=24, color=WHITE, alignment=PP_ALIGN.CENTER)

    add_textbox(slide, Inches(1), Inches(4.0), Inches(11), Inches(0.5),
                'Akhil Sriram',
                font_size=28, color=WHITE, bold=True, alignment=PP_ALIGN.CENTER)

    add_textbox(slide, Inches(1), Inches(4.7), Inches(11), Inches(0.5),
                'Supervisor: Dr. Venkatnarayan Hariharan',
                font_size=20, color=LIGHT_GRAY, alignment=PP_ALIGN.CENTER)

    add_textbox(slide, Inches(1), Inches(5.3), Inches(11), Inches(0.5),
                'Department of Electrical Engineering, Shiv Nadar University',
                font_size=18, color=LIGHT_GRAY, alignment=PP_ALIGN.CENTER)

    add_textbox(slide, Inches(1), Inches(6.2), Inches(11), Inches(0.5),
                'Spring 2026',
                font_size=20, color=TITLE_COLOR, alignment=PP_ALIGN.CENTER)

    # Logo if available
    logo_path = fig('logo.jpg')
    if os.path.exists(logo_path):
        slide.shapes.add_picture(logo_path, Inches(5.5), Inches(5.8), width=Inches(2))


def build_survey_slides(prs):
    # Slide 2: The Visual Tracking Problem
    add_bullet_slide(prs,
        'The Visual Tracking Problem',
        [
            'Given: Frame 1 + bounding box around target',
            'Goal: Find the same target in Frame 2, 3, 4, ...',
            'Naive approach: Slide template across entire search area',
            '    Complexity: O(N^4) — far too slow for real-time',
            'Key insight: Use the FFT to test ALL shifts at once',
            '    Frequency-domain correlation: O(N^2 log N)',
            '    Enables real-time tracking at 100+ FPS',
        ],
        image_path=fig('graphic for explaining.png'))

    # Slide 3: MOSSE Filter
    add_equation_bullet_slide(prs,
        'MOSSE: Minimum Output Sum of Squared Error',
        eq('eq_mosse_filter.png'),
        [
            'Learn filter H* in the frequency domain from training frames',
            'Detection: G = H* (element-wise) F — single FFT + multiply + IFFT',
            'Achieves 600+ FPS on a single CPU core (Bolme et al., CVPR 2010)',
            'Limitation: Operates on raw pixel intensities only',
            'Cannot handle non-linear appearance changes (rotation, lighting)',
            'Only captures linear correlations — low robustness to clutter',
        ])

    # Slide 4: KCF Tracker
    add_bullet_slide(prs,
        'KCF: Kernelized Correlation Filter',
        [
            'Extends MOSSE with the kernel trick (Henriques et al., 2015)',
            'Maps patches into higher-dimensional feature space',
            'Key insight: Kernel correlations of circulant data',
            '    are still diagonalised by the DFT!',
            'Linear kernel: equivalent to MOSSE, better regularised',
            'Gaussian kernel: captures non-linear relationships,',
            '    significantly improves robustness to appearance changes',
            'Same O(N^2 log N) complexity as MOSSE',
        ],
        image_path=fig('KCF.png'))

    # Slide 5: Comparison Table
    add_table_slide(prs,
        'MOSSE vs KCF: Why KCF Wins',
        ['Property', 'MOSSE', 'KCF'],
        [
            ['Feature space', 'Raw pixels (linear)', 'Kernel-mapped (non-linear)'],
            ['Core operation', 'H* . F', 'alpha . k^xz'],
            ['Computational backbone', 'FFT / IFFT', 'FFT / IFFT'],
            ['Training complexity', 'O(N^2 log N)', 'O(N^2 log N)'],
            ['Robustness to clutter', 'Low', 'High'],
            ['Non-linear appearance', 'No', 'Yes (Gaussian kernel)'],
            ['OTB-2013 precision', '66.9%', '73.2%'],
            ['Hardware cost', 'Low', 'Low (linear) / Moderate (Gaussian)'],
        ])


def build_theory_slides(prs):
    # Slide 6: Circulant Matrices
    add_equation_bullet_slide(prs,
        'Circulant Matrices and the DFT',
        eq('eq_circulant.png'),
        [
            'All cyclic shifts of a patch x form a circulant matrix C(x)',
            'Circulant matrices are diagonalised by the DFT',
            'Operations on ALL shifts become element-wise in frequency domain',
            'This is why KCF can test every possible displacement in one pass',
            'Complexity drops from O(N^4) spatial to O(N^2 log N) frequency',
        ])

    # Slide 7: Training
    add_equation_bullet_slide(prs,
        'Training: Learning the Filter',
        eq('eq_alpha.png'),
        [
            'Given target patch x and desired Gaussian response y (sigma=2.0)',
            'Linear kernel: K_hat = |X_hat|^2  (power spectrum)',
            'Ridge regression in frequency domain gives alpha_hat',
            'Lambda = 0.01 prevents division by zero, improves stability',
            'Training is done OFFLINE in Python for this MVP',
        ])

    # Slide 8: Detection
    add_equation_bullet_slide(prs,
        'Detection: Locating the Target',
        eq('eq_detect.png'),
        [
            'Given new search patch z from the next frame:',
            '1. Apply Hann window to z, compute FFT(z)',
            '2. Element-wise multiply: conj(X) * Z_hat * alpha_hat',
            '3. Inverse FFT gives the response map (32x32 real values)',
            '4. Peak of response = displacement of target between frames',
            'Entire detection: one FFT + one multiply + one IFFT',
        ])

    # Slide 9: Combined Filter
    add_equation_bullet_slide(prs,
        'Combined Filter for Hardware',
        eq('eq_combined.png'),
        [
            'Hardware multiplier computes: a * conj(b)',
            'Store f_stored = conj(alpha) * X  in a single ROM',
            'At detection: Z_hat * conj(f_stored) = conj(X) * Z * alpha',
            'This IS the correct KCF detection equation!',
            'Advantage: One ROM instead of two, no Verilog changes needed',
        ])

    # Slide 10: DFT Displacement
    add_bullet_slide(prs,
        'DFT Displacement Convention',
        [
            'Response map uses circular (DFT) indexing:',
            '    Index 0, 1, 2, ...  = positive displacement',
            '    Index 31, 30, 29, ... = negative displacement (-1, -2, -3, ...)',
            '',
            'Unwrapping rule (N=32):',
            '    If peak < 16:  displacement = +peak',
            '    If peak >= 16: displacement = peak - 32',
            '',
            'Example: peak at (29, 30)',
            '    29 - 32 = -3 rows,  30 - 32 = -2 cols',
            '    Target moved 3 pixels up, 2 pixels left',
        ])

    # Slide 11: Hann Window
    add_image_slide(prs,
        'The Hann Window: Preventing Spectral Leakage',
        fig('fig_pres_hann_effect.png'),
        'The Hann window smoothly tapers patch edges to zero, preventing sharp boundary artifacts in the FFT.')


def build_hardware_slides(prs):
    # Slide 12: Architecture Overview
    add_bullet_slide(prs,
        'Hardware Architecture Overview',
        [
            '7-stage Finite State Machine in kcf_detect_top.sv',
            'Input: 32x32 patch (1024 pixels, Q8.8 fixed-point)',
            'Output: (peak_row, peak_col) = target displacement',
            '',
            'Total latency: ~19,300 clock cycles',
            'At 100 MHz: ~193 microseconds per detection',
            'Throughput: ~5,200 detections/second',
            '',
            'All arithmetic in Q8.8 (16-bit signed, 8 fractional bits)',
        ])

    # Slide 13: Pipeline Stages
    add_bullet_slide(prs,
        'Pipeline Stages',
        [
            '1. S_HANN_WIN    (1024 cyc)  — Apply 2D Hann window',
            '2. S_FFT_LOAD    (1024 cyc)  — Load windowed patch into FFT',
            '3. S_FFT_RUN     (~5400 cyc) — 2D FFT (32 rows + 32 cols)',
            '4. S_ELEM_MUL    (1024 cyc)  — Conjugate multiply with filter',
            '5. S_IFFT_LOAD   (1024 cyc)  — Load product into IFFT',
            '6. S_IFFT_RUN    (~6400 cyc) — 2D IFFT (conjugate trick)',
            '7. S_PEAK_RUN    (1026 cyc)  — Scan response, find maximum',
            '',
            'Pipeline is fully sequential — one stage at a time',
            'Each 1D FFT: 5 butterfly stages x 16 operations = 80 ops',
        ])

    # Slide 14: Q8.8 Fixed Point
    add_bullet_slide(prs,
        'Q8.8 Fixed-Point Representation',
        [
            '16-bit signed: 1 sign + 7 integer + 8 fractional bits',
            'Range: -128.000 to +127.996',
            'Resolution: 1/256 = 0.00390625',
            '',
            'THE PROBLEM:',
            '  2D FFT scales by 1/N per pass = 1/N^2 = 1/1024 total',
            '  Response values fall below smallest Q8.8 value!',
            '  Everything rounds to zero',
            '',
            'This required a careful scaling solution...',
        ])

    # Slide 15: Asymmetric Scaling
    add_bullet_slide(prs,
        'The Scaling Solution',
        [
            'Asymmetric FFT Scaling:',
            '  Forward FFT: scale row pass (1/N), skip column pass',
            '  IFFT: full scaling on both passes for correct normalisation',
            '  Net forward attenuation: 1/N (not 1/N^2)',
            '',
            'Adaptive Pre-Scaling:',
            '  Multiply filter coefficients by K (largest power of 2',
            '  such that max|filter * K| < 120)',
            '  Synthetic data: K=64, Real image: K=2',
            '',
            'Final output = (K/N) x true_response',
            '  Comfortably within Q8.8 dynamic range',
        ])

    # Slide 16: Building Blocks
    add_bullet_slide(prs,
        'Key RTL Building Blocks',
        [
            'Butterfly Unit (butterfly.sv):',
            '  out_a = a + W*b,  out_b = a - W*b',
            '  Single-cycle combinational, with scaled variant (>>1)',
            '',
            'Twiddle ROM (twiddle_rom_32.sv):',
            '  16 complex values, symmetry: W^(k+N/2) = -W^k',
            '',
            '1D FFT (fft1d_32.sv): Radix-2 DIT, iterative single-butterfly',
            '2D FFT (fft2d_32.sv): Row-column decomposition',
            '2D IFFT (ifft2d_32.sv): Conjugate trick reuses FFT hardware',
            '  IFFT(X) = conj(FFT(conj(X))) / N^2',
            '',
            'Peak Finder (peak_finder.sv): Sequential max scan, 1026 cycles',
        ])


def build_results_slides(prs):
    # Slide 17: Target Selection
    add_image_slide(prs,
        'Real Image: Target Selection',
        fig('fig_pres_frame1_context.png'),
        'Test image: soccer ball on pavement (284x533). Target: textured ground at (240, 300).')

    # Slide 18: Patch Comparison
    add_image_slide(prs,
        'Simulated Frame-to-Frame Motion',
        fig('fig_pres_patch_comparison.png'),
        'Search patch cropped 3 rows down, 2 cols right. Difference map highlights shifted content at edges.')

    # Slide 19: Detection Result
    add_image_slide(prs,
        'Detection Result on Real Image',
        fig('fig_pres_detection_result.png'),
        'KCF correctly detects displacement (-3, -2) — matching the simulated 3-pixel shift.')

    # Slide 20: Response Map (2D + 3D)
    add_two_image_slide(prs,
        'Response Map: Algorithm Confidence',
        fig('fig_response_map.png'),
        fig('fig_pres_response_3d.png'),
        '2D heatmap (centred with fftshift)',
        '3D surface — sharp peak at (-3, -2)')

    # Slide 21: Pipeline demo
    add_image_slide(prs,
        'KCF Detection Pipeline: Input to Output',
        fig('fig_pipeline_demo.png'),
        '(a) Target patch  (b) Hann-windowed  (c) Search patch  (d) Response map with detected displacement')

    # Slide 22: HW-SW Agreement
    add_two_image_slide(prs,
        'Hardware-Software Agreement',
        fig('Output.png'),
        fig('zoomed in.png'),
        'Python golden reference: peak (29, 30) = displacement (-3, -2)',
        'Vivado waveform: done pulse at ~193 us, matching peak coordinates')


def build_future_slides(prs):
    # Slide 23: Real vs Demo
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    set_bg(slide)

    add_textbox(slide, Inches(0.6), Inches(0.3), Inches(12), Inches(0.8),
                'Real Tracking System vs Our Demo',
                font_size=32, color=TITLE_COLOR, bold=True)

    # Left column: Real System
    add_textbox(slide, Inches(0.6), Inches(1.3), Inches(5.5), Inches(0.5),
                'Real Tracking System', font_size=24, color=RED, bold=True)
    txL = slide.shapes.add_textbox(Inches(0.6), Inches(1.9), Inches(5.5), Inches(4.5))
    tf = txL.text_frame
    tf.word_wrap = True
    for b in ['Continuous video stream (30+ FPS)',
              'Model updates every frame',
              'Larger patches (64x64 or 128x128)',
              'Gaussian kernel for robustness',
              'AXI bus for pixel streaming',
              'Handles occlusion, scale changes',
              'Real-time closed-loop operation']:
        p = tf.add_paragraph() if tf.paragraphs[0].text else tf.paragraphs[0]
        p.text = b
        p.font.size = Pt(18)
        p.font.color.rgb = WHITE
        p.space_after = Pt(6)

    # Right column: Our MVP
    add_textbox(slide, Inches(7), Inches(1.3), Inches(5.5), Inches(0.5),
                'Our Mid-Semester MVP', font_size=24, color=GREEN, bold=True)
    txR = slide.shapes.add_textbox(Inches(7), Inches(1.9), Inches(5.5), Inches(4.5))
    tf = txR.text_frame
    tf.word_wrap = True
    for b in ['Single image, simulated motion',
              'Frozen offline-trained filter',
              '32x32 patches',
              'Linear kernel (simpler hardware)',
              'Direct write port (no AXI)',
              'Detection phase only',
              '~193 us per detection at 100 MHz']:
        p = tf.add_paragraph() if tf.paragraphs[0].text else tf.paragraphs[0]
        p.text = b
        p.font.size = Pt(18)
        p.font.color.rgb = WHITE
        p.space_after = Pt(6)

    # Divider line
    shape = slide.shapes.add_shape(1, Inches(6.5), Inches(1.3), Pt(2), Inches(5))
    shape.fill.solid()
    shape.fill.fore_color.rgb = LIGHT_GRAY
    shape.line.fill.background()

    # Slide 24: What We Achieved
    add_bullet_slide(prs,
        'What We Achieved',
        [
            'Complete 7-stage KCF detection pipeline in synthesisable SystemVerilog',
            'Custom 2D FFT/IFFT using iterative single-butterfly architecture',
            'Q8.8 fixed-point with asymmetric scaling — solved precision challenge',
            'Correct combined-filter formulation for hardware efficiency',
            'Python toolchain: training, data generation, golden reference',
            'Real-image demonstration with exact HW-SW agreement',
            '~19,300 cycles = 193 us per detection at 100 MHz',
            'Verified in both Icarus Verilog and Xilinx Vivado 2024.2',
        ])

    # Slide 25: Future Work
    add_bullet_slide(prs,
        'Future Work Roadmap',
        [
            '1. FPGA Synthesis: Deploy on Xilinx Artix-7,',
            '     evaluate timing, resource consumption, power',
            '',
            '2. Resolution Scaling: 64x64 patches',
            '     (6th FFT stage, 4x memory buffers)',
            '',
            '3. Gaussian Kernel: Hardware exponential LUT',
            '     for improved tracking robustness',
            '',
            '4. Online Model Update: Adapt filter to appearance',
            '     changes in real-time (rotation, lighting)',
            '',
            '5. AXI4-Stream Interface: SoC integration with',
            '     DMA pixel streaming from camera',
        ])

    # Slide 26: Thank You
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    set_bg(slide)

    add_textbox(slide, Inches(1), Inches(2.5), Inches(11), Inches(1),
                'Thank You',
                font_size=52, color=TITLE_COLOR, bold=True,
                alignment=PP_ALIGN.CENTER)

    add_textbox(slide, Inches(1), Inches(4.0), Inches(11), Inches(0.6),
                'Questions?',
                font_size=32, color=WHITE, alignment=PP_ALIGN.CENTER)

    add_textbox(slide, Inches(1), Inches(5.5), Inches(11), Inches(0.5),
                'Akhil Sriram  |  ECE499  |  Spring 2026  |  Shiv Nadar University',
                font_size=18, color=LIGHT_GRAY, alignment=PP_ALIGN.CENTER)


# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

def main():
    # Check for required figures
    required = [
        'fig_pres_frame1_context.png', 'fig_pres_detection_result.png',
        'fig_pres_patch_comparison.png', 'fig_pres_response_3d.png',
        'fig_pres_hann_effect.png', 'fig_pres_gaussian_label.png',
        'fig_response_map.png', 'fig_pipeline_demo.png',
    ]
    missing = [f for f in required if not os.path.exists(fig(f))]
    if missing:
        print('WARNING: Missing figures (run kcf_real_image.py --presentation first):')
        for f in missing:
            print(f'  {f}')
        print('Continuing anyway — missing images will be skipped.\n')

    prs = Presentation()
    prs.slide_width = SLIDE_W
    prs.slide_height = SLIDE_H

    print('Building presentation...')

    build_title_slide(prs)
    print('  Section 0: Title slide')

    build_survey_slides(prs)
    print('  Section 1: Survey (4 slides)')

    build_theory_slides(prs)
    print('  Section 2: KCF Theory (6 slides)')

    build_hardware_slides(prs)
    print('  Section 3: Hardware Pipeline (5 slides)')

    build_results_slides(prs)
    print('  Section 4: Real Image Demo (6 slides)')

    build_future_slides(prs)
    print('  Section 5: Future Work (4 slides)')

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    prs.save(OUT_PATH)
    print(f'\nSaved: {OUT_PATH}')
    print(f'Total slides: {len(prs.slides)}')


if __name__ == '__main__':
    main()
