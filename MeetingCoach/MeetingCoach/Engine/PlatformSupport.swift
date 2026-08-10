import Foundation

/// Architecture gate for the CoreML speech models.
///
/// FluidAudio's models (Parakeet ASR, LS-EEND diarization) are built and
/// validated for Apple Silicon only. On Intel Macs inference falls to
/// Apple's x86 Espresso CPU kernels, where the first real window kills the
/// process with an uncatchable SIGFPE (divide-by-zero in
/// `general_padding_kernel_cpu` — customer crash report, 0.17.0, iMac20,1).
/// A signal on a dispatch queue never reaches Swift error handling, so the
/// only defense is to never start that inference: Intel sessions run on
/// SFSpeech with diarization off, and the UI says so.
enum PlatformSupport {
    #if arch(arm64)
    static let neuralModelsSupported = true
    #else
    static let neuralModelsSupported = false
    #endif
}
