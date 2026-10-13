import Accelerate
import Foundation

/// Turns the newest 8192 mix samples into band levels in dB, full-scale sine = 0 dB. As
/// multi-resolution analyzers do, bands under 300 Hz read all 8192 (186 ms at 44.1 kHz), so
/// low notes stay narrow on the log axis, and the rest read the newest 4096 (93 ms), so the
/// highs keep up. Each is zero-padded to twice its length: finer bins, no more delay. A
/// Blackman-Harris window keeps each note's leakage 92 dB down: valleys stay deep.
struct SpectrumAnalyzer {
  // ceiling: 400 fixed bands; finer needs more GPU vertices per row and a wider ring.
  static let size = 8192, bands = 400, crossover: Float = 300
  static let minFrequency: Float = 20, maxFrequency: Float = 20000
  /// How far past the moment heard the samples should run, when the output has them: the
  /// short window's centre then sits on what you hear now.
  static let ahead = 2048
  /// The rate the samples were played at: the output device's.
  var rate: Float = 44100
  private let long = Resolution(size: 8192), short = Resolution(size: 4096)

  /// One window size, zero-padded to twice it: magnitudes of the newest samples, a
  /// full-scale sine peaking at 1, in bins `rate / (2 * size)` wide.
  private struct Resolution {
    static let terms: [Float] = [0.35875, -0.48829, 0.14128, -0.01168]
    let size: Int, fft: vDSP.FFT<DSPSplitComplex>, window: [Float]
    init(size: Int) {
      self.size = size
      fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(size * 2))), radix: .radix2, ofType: DSPSplitComplex.self)!
      window = (0..<size).map { n in
        Self.terms.enumerated().reduce(0) { $0 + $1.element * cos(2 * .pi * Float($1.offset * n) / Float(size)) }
      }
    }
    func magnitudes(_ samples: [Float]) -> [Float] {
      let windowed = vDSP.multiply(samples.suffix(size), window) + [Float](repeating: 0, count: size)
      var real = [Float](repeating: 0, count: size), imag = real, magnitudes = real
      real.withUnsafeMutableBufferPointer { re in
        imag.withUnsafeMutableBufferPointer { im in
          var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
          windowed.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size)) }
          fft.forward(input: split, output: &split)
          split.imagp[0] = 0  // zrip packs Nyquist there; DC and Nyquist are below and above the axis anyway
          vDSP.absolute(split, result: &magnitudes)
        }
      }
      // zrip doubles, the window scales by its mean: a full-scale sine peaks at size * mean.
      return vDSP.multiply(1 / (Float(size) * Self.terms[0]), magnitudes)
    }
  }

  /// Band centre frequencies, log or linearly spaced.
  static func frequencies(log: Bool) -> [Float] {
    (0..<bands).map { i in
      let t = Float(i) / Float(bands - 1)
      return log ? minFrequency * pow(maxFrequency / minFrequency, t) : minFrequency + (maxFrequency - minFrequency) * t
    }
  }
  /// Where a frequency sits across the axis, 0 to 1.
  static func position(_ frequency: Float, log: Bool) -> CGFloat {
    CGFloat(log ? Foundation.log(frequency / minFrequency) / Foundation.log(maxFrequency / minFrequency)
      : (frequency - minFrequency) / (maxFrequency - minFrequency))
  }

  func levels(_ samples: [Float], log: Bool) -> [Float] {
    precondition(samples.count == Self.size)
    let spectra = [long, short].map { (rate / Float(2 * $0.size), $0.magnitudes(samples)) }
    let centres = Self.frequencies(log: log), ratio = log ? pow(Self.maxFrequency / Self.minFrequency, 0.5 / Float(Self.bands - 1)) : 1
    let half = log ? 0 : (Self.maxFrequency - Self.minFrequency) / Float(Self.bands - 1) / 2
    return centres.map { f in
      let (binWidth, magnitudes) = spectra[f < Self.crossover ? 0 : 1]
      let lo = (log ? f / ratio : f - half) / binWidth, hi = (log ? f * ratio : f + half) / binWidth
      var peak: Float
      if hi - lo < 1 {  // narrower than a bin: interpolate between the two nearest
        let x = min(Float(magnitudes.count - 2), f / binWidth), k = Int(x)
        peak = magnitudes[k] + (magnitudes[k + 1] - magnitudes[k]) * (x - Float(k))
      } else {
        peak = magnitudes[max(1, Int(lo.rounded(.up)))...min(magnitudes.count - 1, Int(hi))].max() ?? 0
      }
      return 20 * log10(max(peak, 1e-7))
    }
  }
}

/// The mix as heard and the original song, over the same moments, at the output's rate.
struct Scope {
  var mix: [Float]
  var original: [Float]
  var rate: Float
}
