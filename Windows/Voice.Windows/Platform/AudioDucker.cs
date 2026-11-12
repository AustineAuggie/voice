using System;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;

namespace Voice.Windows.Platform;

/// <summary>Only dictation should own this lease. Meeting recording must not mute remote participants.</summary>
public sealed class AudioDucker : IDisposable
{
    private readonly object gate = new();
    private MMDevice? device;
    private bool previousMute;

    public void Mute()
    {
        lock (gate)
        {
            if (device is not null) return;
            using var devices = new MMDeviceEnumerator();
            var output = devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            try
            {
                previousMute = output.AudioEndpointVolume.Mute;
                output.AudioEndpointVolume.Mute = true;
                device = output;
            }
            catch { output.Dispose(); throw; }
        }
    }

    public void Restore()
    {
        lock (gate)
        {
            if (device is null) return;
            var output = device; device = null;
            try
            {
                // Do not overwrite a manual unmute made while dictating.
                if (output.AudioEndpointVolume.Mute) output.AudioEndpointVolume.Mute = previousMute;
            }
            catch (ExternalException) { /* An unplugged endpoint no longer has a mute state to restore. */ }
            catch (InvalidOperationException) { }
            finally { try { output.Dispose(); } catch (ExternalException) { } }
        }
    }

    public void Dispose() { try { Restore(); } catch { /* The device may have been unplugged. */ } }
}
