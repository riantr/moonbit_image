// Copyright (c) 2026 RiantR
// FIM (CETC BVE-series X-ray) raw image decoder
//
// ".fim" is the raw detector stream of a CETC BVE-series X-ray security
// scanner.  The header is little-endian and 230 bytes long; it carries the
// detector channel count at 0x14 and the payload size in bytes at 0x20.  The
// payload is a column-major stream of 16-bit little-endian samples, one whole
// column per conveyor position:
//
//   stream = [col0_top, col0_bottom, col1_top, col1_bottom, ...]
//   height = data_size / (width * 2)
//   arr[i, j] = stream[j * height + i]     (i = row, j = detector channel)
//
// The scanner interleaves the two dual-energy exposures in time, so the even
// and odd ROWS of the decoded image are the low- and high-energy halves.  Like
// the other `decode_*` entry points, `decode_fim` returns a single `Image`, and
// that image lays the two halves out side by side -- `low | high`, each of size
// (width, height / 2) -- so a plain image viewer shows both at once.
//
// This package has no single-channel 16-bit pixel format, so the raw detector
// image is exposed as `decode_fim_raw` (a `GrayA8` image carrying the 16-bit
// samples big-endian); the display image returned by `decode_fim` is 8-bit
// `Gray8`.  The legacy even/odd COLUMN split is `fim_split_cols`, and the
// dual-energy ratio is available through the `fim_ratio_*` renderers.

//-----------------------------------------------------------------------------
// Header constants
//-----------------------------------------------------------------------------

///|
const FIM_HEADER_BYTES : Int = 0xE6

///|
const FIM_SRGB_GAMMA : Double = 2.2

//-----------------------------------------------------------------------------
// FIM Decoder
//-----------------------------------------------------------------------------

///|
/// Decode a FIM image from raw bytes into a single, display-ready `Image`.
///
/// The two dual-energy halves are laid out side by side -- low energy (even
/// rows) on the left, high energy (odd rows) on the right -- giving a `Gray8`
/// image of size (2 * detector_width, detector_height / 2).  Each half uses the
/// viewer defaults (sRGB degamma, [1, 99] percentile stretch, inverted) that
/// match the reference PNGs; call `fim_to_grayscale8` for other choices, or
/// `decode_fim_raw` for the raw 16-bit data.
pub fn decode_fim(data : Bytes) -> Image raise Failure {
  let raw = decode_fim_raw(data)
  // Display orientation: the detector stream is bottom-up.
  let oriented = raw.flip_vertical()
  let (low, high) = fim_split_rows(oriented)
  let left = fim_to_grayscale8(
    low,
    invert=true,
    degamma=true,
    percentile_low=Some(1.0),
    percentile_high=Some(99.0),
  )
  let right = fim_to_grayscale8(
    high,
    invert=true,
    degamma=true,
    percentile_low=Some(1.0),
    percentile_high=Some(99.0),
  )
  fim_side_by_side(left, right)
}

///|
/// Decode the raw detector image: a `GrayA8` image of size
/// (detector_width, detector_height) whose two bytes per pixel hold the 16-bit
/// little-endian sample big-endian (high byte first).  No flip and no split.
pub fn decode_fim_raw(data : Bytes) -> Image raise Failure {
  let decoder = FimDecoder::new(data)
  decoder.decode()
}

///|
/// FIM decoder state machine
priv struct FimDecoder {
  data : Bytes
  width : Int
  height : Int
  payload_start : Int
}

///|
fn FimDecoder::new(data : Bytes) -> FimDecoder raise Failure {
  if data.length() < FIM_HEADER_BYTES + 2 {
    raise Failure::Failure("FIM: file too small: \{data.length()} bytes")
  }
  if data[0].to_int() != 0x4A || data[1].to_int() != 0x41 {
    raise Failure::Failure("FIM: invalid magic, expected 'JA'")
  }
  let width = read_u32_le(data, 0x14)
  let data_size = read_u32_le(data, 0x20)
  let header_end = data.length() - data_size
  if header_end != FIM_HEADER_BYTES {
    raise Failure::Failure(
      "FIM: header size mismatch: computed=\{header_end} expected=\{FIM_HEADER_BYTES}",
    )
  }
  if width <= 0 {
    raise Failure::Failure("FIM: invalid detector width: \{width}")
  }
  if data_size % (width * 2) != 0 {
    raise Failure::Failure(
      "FIM: payload not 16-bit aligned: \{data_size} % \{width * 2}",
    )
  }
  let height = data_size / (width * 2)
  { data, width, height, payload_start: header_end, }
}

///|
fn FimDecoder::decode(self : FimDecoder) -> Image raise Failure {
  let w = self.width
  let h = self.height
  let pixels = FixedArray::make(w * h * 2, b'\x00')
  for j = 0; j < w; j = j + 1 {
    let col_base = j * h
    for i = 0; i < h; i = i + 1 {
      let off = self.payload_start + (col_base + i) * 2
      let sample = self.data[off].to_int() | (self.data[off + 1].to_int() << 8)
      let o = (i * w + j) * 2
      pixels[o] = ((sample >> 8) & 0xFF).to_byte()
      pixels[o + 1] = (sample & 0xFF).to_byte()
    }
  }
  Image::new(w, h, PixelFormat::GrayA8, Bytes::from_array(pixels))
}

///|
/// Read the detector dimensions (width, height) from the header, without
/// decoding.  `decode_fim` returns an image of size
/// (2 * width, height / 2).
pub fn fim_dimensions(data : Bytes) -> (Int, Int) raise Failure {
  let decoder = FimDecoder::new(data)
  (decoder.width, decoder.height)
}

//-----------------------------------------------------------------------------
// Pixel helpers — 16-bit samples stored big-endian in a GrayA8 image
//-----------------------------------------------------------------------------

///|
fn fim_sample(img : Image, x : Int, y : Int) -> Int {
  let i = (y * img.width + x) * 2
  (img.data[i].to_int() << 8) | img.data[i + 1].to_int()
}

///|
fn fim_store(
  pixels : FixedArray[Byte],
  w : Int,
  x : Int,
  y : Int,
  v : Int,
) -> Unit {
  let i = (y * w + x) * 2
  pixels[i] = ((v >> 8) & 0xFF).to_byte()
  pixels[i + 1] = (v & 0xFF).to_byte()
}

///|
fn fim_gray_a8(w : Int, h : Int, pixels : FixedArray[Byte]) -> Image {
  Image::new(w, h, PixelFormat::GrayA8, Bytes::from_array(pixels))
}

//-----------------------------------------------------------------------------
// Geometry
//-----------------------------------------------------------------------------

///|
/// Lay two images of equal height out horizontally (`left | right`).  Any
/// pixel format works, as long as both sides use the same one.
pub fn fim_side_by_side(left : Image, right : Image) -> Image raise Failure {
  if left.height != right.height {
    raise Failure::Failure(
      "FIM: cannot join images of different heights: \{left.height} vs \{right.height}",
    )
  }
  let bpp = left.bytes_per_pixel()
  if right.bytes_per_pixel() != bpp {
    raise Failure::Failure(
      "FIM: cannot join images of different pixel sizes: \{bpp} vs \{right.bytes_per_pixel()}",
    )
  }
  let w = left.width + right.width
  let h = left.height
  let stride_l = left.width * bpp
  let stride_r = right.width * bpp
  let out = FixedArray::make(w * h * bpp, b'\x00')
  for y = 0; y < h; y = y + 1 {
    for i = 0; i < stride_l; i = i + 1 {
      out[y * w * bpp + i] = left.data[y * stride_l + i]
    }
    for i = 0; i < stride_r; i = i + 1 {
      out[y * w * bpp + stride_l + i] = right.data[y * stride_r + i]
    }
  }
  Image::new(w, h, left.format, Bytes::from_array(out))
}

///|
/// Split by rows (the time axis): even rows = low energy, odd rows = high
/// energy.  Both outputs have shape (height / 2, width).
pub fn fim_split_rows(img : Image) -> (Image, Image) raise Failure {
  let w = img.width
  let h = img.height
  let hs = h / 2
  let even = FixedArray::make(w * hs * 2, b'\x00')
  let odd = FixedArray::make(w * hs * 2, b'\x00')
  for r = 0; r < hs; r = r + 1 {
    for c = 0; c < w; c = c + 1 {
      fim_store(even, w, c, r, fim_sample(img, c, 2 * r))
      fim_store(odd, w, c, r, fim_sample(img, c, 2 * r + 1))
    }
  }
  (fim_gray_a8(w, hs, even), fim_gray_a8(w, hs, odd))
}

///|
/// Split by columns (the detector-channel axis): even columns and odd columns.
/// Both outputs have shape (height, width / 2).
pub fn fim_split_cols(img : Image) -> (Image, Image) raise Failure {
  let w = img.width
  let h = img.height
  let ws = w / 2
  let even = FixedArray::make(ws * h * 2, b'\x00')
  let odd = FixedArray::make(ws * h * 2, b'\x00')
  for r = 0; r < h; r = r + 1 {
    for c = 0; c < ws; c = c + 1 {
      fim_store(even, ws, c, r, fim_sample(img, 2 * c, r))
      fim_store(odd, ws, c, r, fim_sample(img, 2 * c + 1, r))
    }
  }
  (fim_gray_a8(ws, h, even), fim_gray_a8(ws, h, odd))
}

///|
/// Cyclic vertical roll: result row y = source row (y - shift) mod h.
/// A positive shift moves content down, matching numpy `roll(shift, axis=0)`.
pub fn fim_apply_y_roll(img : Image, shift_px : Int) -> Image raise Failure {
  let w = img.width
  let h = img.height
  let pixels = FixedArray::make(w * h * 2, b'\x00')
  let sh = (shift_px % h + h) % h
  for y = 0; y < h; y = y + 1 {
    let src = (y - sh + h) % h
    for i = 0; i < w * 2; i = i + 1 {
      pixels[y * w * 2 + i] = img.data[src * w * 2 + i]
    }
  }
  fim_gray_a8(w, h, pixels)
}

//-----------------------------------------------------------------------------
// Bright bottom strip + auto Y roll
//-----------------------------------------------------------------------------

///|
/// Find the bottom-most continuous all-air band: a run of rows whose full-row
/// mean exceeds `air_threshold`.  Returns (top_row, row_count), or (0, 0) when
/// the image is too small or has no such band.
pub fn fim_find_bright_strip(
  img : Image,
  air_threshold? : Double = 50000.0,
) -> (Int, Int) raise Failure {
  let w = img.width
  let h = img.height
  if h < 50 || w < 50 {
    return (0, 0)
  }
  let is_air = FixedArray::make(h, false)
  let mut any = false
  for y = 0; y < h; y = y + 1 {
    let mut sum = 0.0
    for x = 0; x < w; x = x + 1 {
      sum = sum + fim_sample(img, x, y).to_double()
    }
    is_air[y] = sum / w.to_double() > air_threshold
    if is_air[y] {
      any = true
    }
  }
  if !any {
    return (0, 0)
  }
  let mut best_start = -1
  let mut best_len = 0
  let mut run_start = -1
  for y = 0; y < h; y = y + 1 {
    if is_air[y] {
      if run_start < 0 {
        run_start = y
      }
    } else if run_start >= 0 {
      best_start = run_start
      best_len = y - run_start
      run_start = -1
    }
  }
  if run_start >= 0 {
    best_start = run_start
    best_len = h - run_start
  }
  if best_start >= 0 {
    (best_start, best_len)
  } else {
    (0, 0)
  }
}

///|
/// Auto-detect the display Y roll from the bright bottom strip: shift the
/// image up by half the strip height, leaving a small visible top strip.
pub fn fim_find_auto_y_roll(img : Image) -> Int raise Failure {
  let strip = fim_find_bright_strip(img)
  if strip.1 == 0 {
    return 0
  }
  -(strip.1 / 2)
}

//-----------------------------------------------------------------------------
// Grayscale rendering
//-----------------------------------------------------------------------------

///|
/// Render a FIM image as 8-bit grayscale: value = sample / 65535, optional sRGB
/// degamma, optional [low, high] percentile stretch, optional invert, then
/// byte = floor(value * 255 + 0.5).  Returns a `Gray8` image.
pub fn fim_to_grayscale8(
  img : Image,
  invert? : Bool = true,
  degamma? : Bool = false,
  percentile_low? : Double? = Some(1.0),
  percentile_high? : Double? = Some(99.0),
) -> Image raise Failure {
  let w = img.width
  let h = img.height
  let n = w * h
  let vals : Array[Double] = Array::make(n, 0.0)
  let gamma_inv = 1.0 / FIM_SRGB_GAMMA
  let mut k = 0
  for y = 0; y < h; y = y + 1 {
    for x = 0; x < w; x = x + 1 {
      let mut v = fim_sample(img, x, y).to_double() / 65535.0
      if degamma {
        v = v.pow(gamma_inv)
      }
      vals[k] = if v < 0.0 { 0.0 } else if v > 1.0 { 1.0 } else { v }
      k = k + 1
    }
  }
  match (percentile_low, percentile_high) {
    (Some(lo_pct), Some(hi_pct)) => {
      let lo = fim_percentile(vals, lo_pct)
      let mut hi = fim_percentile(vals, hi_pct)
      if hi <= lo {
        hi = lo + 1.0e-6
      }
      let range = hi - lo
      for i = 0; i < n; i = i + 1 {
        let v = (vals[i] - lo) / range
        vals[i] = if v < 0.0 { 0.0 } else if v > 1.0 { 1.0 } else { v }
      }
    }
    _ => ()
  }
  let out = FixedArray::make(n, b'\x00')
  for i = 0; i < n; i = i + 1 {
    let mut v = vals[i]
    if invert {
      v = 1.0 - v
    }
    out[i] = fim_round_half_even(v * 255.0).clamp(min=0, max=255).to_byte()
  }
  Image::new(w, h, PixelFormat::Gray8, Bytes::from_array(out))
}

//-----------------------------------------------------------------------------
// Dual-energy ratio
//-----------------------------------------------------------------------------

///|
/// Dual-energy R map and the statistics the renderers need.
priv struct FimRatio {
  r : FixedArray[Double] // R = P_low / P_high; 0 = invalid (air / no signal)
  p_low : FixedArray[Double] // low-energy log attenuation ln(I0 / I_low)
  w : Int
  h : Int
  sig_ref : Double // 98th percentile of valid P_low (pseudo-color reference)
  norm_lo : Double
  norm_hi : Double
}

///|
/// Compute the dual-energy ratio image from the low- and high-energy halves:
///
///   P_energy = ln(I0 / I_energy)     (log attenuation)
///   R        = P_low / P_high
///
/// I0 per half is the `i0_percentile` of its samples (the saturated air level).
/// Pixels without usable attenuation in either half get R = 0.
fn fim_compute_ratio(
  low : Image,
  high : Image,
  i0_percentile? : Double = 99.0,
  norm_low_pct? : Double = 2.0,
  norm_high_pct? : Double = 98.0,
) -> FimRatio raise Failure {
  let w = low.width
  let h = low.height
  if high.width != w || high.height != h {
    raise Failure::Failure(
      "FIM: low/high size mismatch: \{w}x\{h} vs \{high.width}x\{high.height}",
    )
  }
  let low_vals : Array[Double] = []
  let high_vals : Array[Double] = []
  for y = 0; y < h; y = y + 1 {
    for x = 0; x < w; x = x + 1 {
      low_vals.push(fim_sample(low, x, y).to_double())
      high_vals.push(fim_sample(high, x, y).to_double())
    }
  }
  let i0_low = fim_percentile(low_vals, i0_percentile).max(1.0)
  let i0_high = fim_percentile(high_vals, i0_percentile).max(1.0)
  let r = FixedArray::make(w * h, 0.0)
  let p_low = FixedArray::make(w * h, 0.0)
  let valid : Array[Double] = []
  let valid_pls : Array[Double] = []
  let eps = 1.0e-6
  let mut k = 0
  for y = 0; y < h; y = y + 1 {
    for x = 0; x < w; x = x + 1 {
      let vl = fim_sample(low, x, y).max(1).to_double()
      let vh = fim_sample(high, x, y).max(1).to_double()
      let mut pl = fim_ln(i0_low / vl)
      if pl < 0.0 {
        pl = 0.0
      }
      let mut ph = fim_ln(i0_high / vh)
      if ph < 0.0 {
        ph = 0.0
      }
      p_low[k] = pl
      if ph > eps && pl > eps {
        let rr = pl / ph
        r[k] = rr
        valid.push(rr)
        valid_pls.push(pl)
      }
      k = k + 1
    }
  }
  let mut sig_ref = 1.0
  if valid_pls.length() > 10 {
    sig_ref = fim_percentile(valid_pls, 98.0)
    if sig_ref <= 1.0e-6 {
      sig_ref = 1.0
    }
  }
  let mut norm_lo = 1.0
  let mut norm_hi = 2.0
  if valid.length() > 10 {
    norm_lo = fim_percentile(valid, norm_low_pct)
    norm_hi = fim_percentile(valid, norm_high_pct)
    if norm_hi <= norm_lo {
      norm_hi = norm_lo + 1.0e-6
    }
  }
  { r, p_low, w, h, sig_ref, norm_lo, norm_hi, }
}

///|
fn fim_normalize(ratio : FimRatio, value : Double) -> Double {
  let v = (value - ratio.norm_lo) / (ratio.norm_hi - ratio.norm_lo)
  if v < 0.0 {
    0.0
  } else if v > 1.0 {
    1.0
  } else {
    v
  }
}

///|
/// Render the R map as 8-bit grayscale (bright = high R), black where invalid.
pub fn fim_ratio_grayscale(low : Image, high : Image) -> Image raise Failure {
  let ratio = fim_compute_ratio(low, high)
  let n = ratio.w * ratio.h
  let out = FixedArray::make(n, b'\x00')
  for i = 0; i < n; i = i + 1 {
    let b = if ratio.r[i] == 0.0 {
      0
    } else {
      fim_round_half_even(fim_normalize(ratio, ratio.r[i]) * 255.0).clamp(
        min=0,
        max=255,
      )
    }
    out[i] = b.to_byte()
  }
  Image::new(ratio.w, ratio.h, PixelFormat::Gray8, Bytes::from_array(out))
}

///|
/// Render the R map through the security-inspection pseudo-color palette
/// (blue = low R / organic, red = high R / metallic), black where invalid.
pub fn fim_ratio_pseudo_color(low : Image, high : Image) -> Image raise Failure {
  let ratio = fim_compute_ratio(low, high)
  let n = ratio.w * ratio.h
  let out = FixedArray::make(n * 3, b'\x00')
  for i = 0; i < n; i = i + 1 {
    if ratio.r[i] != 0.0 {
      let (cr, cg, cb) = fim_palette_color(fim_normalize(ratio, ratio.r[i]))
      out[i * 3] = cr.to_byte()
      out[i * 3 + 1] = cg.to_byte()
      out[i * 3 + 2] = cb.to_byte()
    }
  }
  Image::new(ratio.w, ratio.h, PixelFormat::RGB8, Bytes::from_array(out))
}

///|
/// Render vendor-style HSB pseudo color: hue follows clip(P_low / SigRef, 0..1),
/// full saturation and brightness; invalid pixels stay black.
pub fn fim_ratio_pseudo_color_hsb(
  low : Image,
  high : Image,
) -> Image raise Failure {
  let ratio = fim_compute_ratio(low, high)
  let n = ratio.w * ratio.h
  let out = FixedArray::make(n * 3, b'\x00')
  for i = 0; i < n; i = i + 1 {
    let pl = ratio.p_low[i]
    if !(ratio.r[i] == 0.0 || pl <= 0.0) {
      let mut t = pl / ratio.sig_ref
      if t < 0.0 {
        t = 0.0
      } else if t > 1.0 {
        t = 1.0
      }
      let (r8, g8, b8) = fim_hsv_to_rgb8(fim_interp_hue(t) / 360.0, 1.0, 1.0)
      out[i * 3] = r8.to_byte()
      out[i * 3 + 1] = g8.to_byte()
      out[i * 3 + 2] = b8.to_byte()
    }
  }
  Image::new(ratio.w, ratio.h, PixelFormat::RGB8, Bytes::from_array(out))
}

//-----------------------------------------------------------------------------
// Numeric helpers
//-----------------------------------------------------------------------------

///|
/// numpy.percentile(a, q) with linear interpolation ("linear" method).
fn fim_percentile(vals : Array[Double], q : Double) -> Double raise Failure {
  let a = Array::from_iter(vals.iter())
  a.sort()
  let n = a.length()
  if n == 0 {
    raise Failure::Failure("FIM: empty percentile input")
  }
  if n == 1 {
    return a[0]
  }
  let pos = (n - 1).to_double() * q / 100.0
  let mut lo_idx = pos.to_int()
  if lo_idx > n - 2 {
    return a[n - 1]
  }
  if lo_idx < 0 {
    lo_idx = 0
  }
  let frac = pos - lo_idx.to_double()
  a[lo_idx] + frac * (a[lo_idx + 1] - a[lo_idx])
}

///|
/// Natural logarithm by range reduction plus the atanh series.  Kept local so
/// the package needs no `moonbitlang/core/math` import.
fn fim_ln(x : Double) -> Double {
  if x <= 0.0 {
    return 0.0
  }
  let mut e = 0
  let mut v = x
  while v >= 2.0 {
    v = v / 2.0
    e = e + 1
  }
  while v < 1.0 {
    v = v * 2.0
    e = e - 1
  }
  let z = (v - 1.0) / (v + 1.0)
  let z2 = z * z
  let mut term = z
  let mut sum = z
  let mut k = 3
  for _i = 0; _i < 14; _i = _i + 1 {
    term = term * z2
    sum = sum + term / k.to_double()
    k = k + 2
  }
  2.0 * sum + e.to_double() * 0.6931471805599453
}

///|
/// C# Math.Round / Python round: midpoint rounds to the nearest even value.
fn fim_round_half_even(x : Double) -> Int {
  let fl = x.floor()
  let d = x - fl
  if d > 0.5 {
    fl.to_int() + 1
  } else if d < 0.5 {
    fl.to_int()
  } else if fl % 2.0 == 0.0 {
    fl.to_int()
  } else {
    fl.to_int() + 1
  }
}

///|
/// Pseudo-color palette stops: dark blue -> cyan -> green -> yellow -> red.
let fim_palette_stops : Array[(Double, Int, Int, Int)] = [
  (0.00, 0, 0, 96),
  (0.25, 0, 180, 255),
  (0.50, 60, 220, 60),
  (0.75, 255, 220, 0),
  (1.00, 255, 40, 40),
]

///|
fn fim_palette_color(t : Double) -> (Int, Int, Int) {
  let stops = fim_palette_stops
  if t <= stops[0].0 {
    return (stops[0].1, stops[0].2, stops[0].3)
  }
  let last = stops.length() - 1
  if t >= stops[last].0 {
    return (stops[last].1, stops[last].2, stops[last].3)
  }
  for i = 0; i < last; i = i + 1 {
    let a = stops[i]
    let b = stops[i + 1]
    if t >= a.0 && t <= b.0 {
      let f = (t - a.0) / (b.0 - a.0)
      return (
        fim_round_half_even(a.1.to_double() + f * (b.1 - a.1).to_double()),
        fim_round_half_even(a.2.to_double() + f * (b.2 - a.2).to_double()),
        fim_round_half_even(a.3.to_double() + f * (b.3 - a.3).to_double()),
      )
    }
  }
  (0, 0, 0)
}

///|
/// Hue anchors fitted from the device reference PNGs: progress -> hue (deg).
let fim_hue_stops : Array[(Double, Double)] = [
  (0.00, 0.0),
  (0.05, 10.0),
  (0.35, 55.0),
  (0.45, 70.0),
  (0.70, 165.0),
  (0.85, 195.0),
  (1.00, 265.0),
]

///|
fn fim_interp_hue(t : Double) -> Double {
  let s = fim_hue_stops
  if t <= s[0].0 {
    return s[0].1
  }
  let last = s.length() - 1
  if t >= s[last].0 {
    return s[last].1
  }
  for i = 0; i < last; i = i + 1 {
    if t >= s[i].0 && t <= s[i + 1].0 {
      let f = (t - s[i].0) / (s[i + 1].0 - s[i].0)
      return s[i].1 + f * (s[i + 1].1 - s[i].1)
    }
  }
  s[last].1
}

///|
/// h, s, v in [0, 1] -> 8-bit RGB.
fn fim_hsv_to_rgb8(h : Double, s : Double, v : Double) -> (Int, Int, Int) {
  let h6 = h * 6.0
  let mut i = h6.floor().to_int() % 6
  if i < 0 {
    i = i + 6
  }
  let f = h6 - h6.floor()
  let p = v * (1.0 - s)
  let q = v * (1.0 - s * f)
  let t = v * (1.0 - s * (1.0 - f))
  let (r, g, b) = match i {
    0 => (v, t, p)
    1 => (q, v, p)
    2 => (p, v, t)
    3 => (p, q, v)
    4 => (t, p, v)
    _ => (v, p, q)
  }
  (
    fim_round_half_even(r * 255.0).clamp(min=0, max=255),
    fim_round_half_even(g * 255.0).clamp(min=0, max=255),
    fim_round_half_even(b * 255.0).clamp(min=0, max=255),
  )
}
