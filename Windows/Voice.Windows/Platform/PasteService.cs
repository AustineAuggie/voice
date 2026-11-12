using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace Voice.Windows.Platform;

public sealed record PasteTarget(nint Handle, uint ProcessId);
public sealed record PasteResult(bool Pasted, string Message);

public sealed class PasteService
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private Task<CaretContext?>? caretTask;

    public PasteTarget CaptureTarget()
    {
        var handle = NativeMethods.GetForegroundWindow();
        NativeMethods.GetWindowThreadProcessId(handle, out uint processId);
        return new PasteTarget(handle, processId);
    }

    /// <summary>Must be called on WPF's UI/STA thread. Never sends Enter or submits a form.</summary>
    public async Task<PasteResult> PasteAsync(string text, PasteTarget target, CancellationToken cancellationToken = default)
    {
        Application.Current.Dispatcher.VerifyAccess();
        if (string.IsNullOrWhiteSpace(text)) return new(false, "There is no text to paste.");
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (target.Handle == 0 || target.ProcessId == (uint)Environment.ProcessId || !NativeMethods.IsWindow(target.Handle))
                return new(false, "Text is ready. Click Copy, then paste it into your document. Use Ctrl+Alt+Space while your document is focused for automatic pasting.");
            NativeMethods.GetWindowThreadProcessId(target.Handle, out uint actualProcess);
            if (actualProcess != target.ProcessId) return new(false, "The original document closed. Your text is still available to copy.");

            var foreground = NativeMethods.GetForegroundWindow();
            if (foreground != target.Handle)
            {
                NativeMethods.GetWindowThreadProcessId(foreground, out uint foregroundProcess);
                // A non-activating recording pill normally leaves focus unchanged. Restore only
                // if Voice itself has focus; never paste over a different app the user switched to.
                if (foregroundProcess != (uint)Environment.ProcessId || !NativeMethods.SetForegroundWindow(target.Handle))
                    return new(false, "The focused window changed. Your text is ready to copy and paste.");
                await Task.Delay(80, cancellationToken);
            }

            var deadline = Stopwatch.StartNew();
            while (NativeMethods.ModifiersHeld() && deadline.Elapsed < TimeSpan.FromSeconds(2))
                await Task.Delay(20, cancellationToken);
            if (NativeMethods.ModifiersHeld()) return new(false, "Release the shortcut keys, then use Copy to paste your text.");
            if (NativeMethods.GetForegroundWindow() != target.Handle)
                return new(false, "The focused window changed. Your text is ready to copy.");

            CaretContext? context = null;
            // A hung UI Automation provider must not consume another thread for every dictation.
            if (caretTask is null || caretTask.IsCompleted)
            {
                caretTask = Task.Run(() => GetCaretContext(target.ProcessId));
                var finished = await Task.WhenAny(caretTask, Task.Delay(250, cancellationToken));
                if (finished == caretTask) context = await caretTask;
            }
            if (context?.Password == true) return new(false, "Automatic paste is disabled in password fields. Your text is available in Voice.");
            string insertion = FormatForInsertion(text, context?.Previous, context?.Next);
            cancellationToken.ThrowIfCancellationRequested();

            IDataObject? previous = null;
            bool capturedPrevious = false;
            try { previous = SnapshotClipboard(); capturedPrevious = previous is not null; } catch (ExternalException) { }
            for (int attempt = 0; ; attempt++)
            {
                try { Clipboard.SetText(insertion, TextDataFormat.UnicodeText); break; }
                catch (ExternalException) when (attempt < 4) { await Task.Delay(40, cancellationToken); }
            }
            uint ownClipboard = NativeMethods.GetClipboardSequenceNumber();
            if (NativeMethods.GetForegroundWindow() != target.Handle)
                return new(false, "The focused window changed. Your text has been copied; paste it where you want it.");
            cancellationToken.ThrowIfCancellationRequested();
            var keys = new[] { NativeMethods.Key(NativeMethods.VkControl), NativeMethods.Key(0x56),
                NativeMethods.Key(0x56, true), NativeMethods.Key(NativeMethods.VkControl, true) };
            uint sent = NativeMethods.SendInput((uint)keys.Length, keys, Marshal.SizeOf<NativeMethods.Input>());
            if (sent != keys.Length)
            {
                NativeMethods.SendInput(1, new[] { NativeMethods.Key(NativeMethods.VkControl, true) }, Marshal.SizeOf<NativeMethods.Input>());
                return new(false, "Windows blocked automatic paste. Press Ctrl+V to paste the copied text. Apps running as administrator may block Voice.");
            }
            // Clipboard restoration is delayed but does not hold up the done indicator. The
            // sequence guard protects anything the user copies in the meantime.
            if (capturedPrevious) _ = RestoreClipboardAsync(previous, ownClipboard);
            return new(true, "Paste sent. Your text is also kept in Voice.");
        }
        catch (ExternalException) { return new(false, "Another app is using the clipboard. Your text is ready to copy in Voice."); }
        finally { gate.Release(); }
    }

    public static string FormatForInsertion(string text, char? previous, char? next)
    {
        string value = text.Trim();
        if (value.Length == 0) return value;
        bool startsClosing = ",.;:!?)]}”’".Contains(value[0]);
        bool previousOpening = previous is '(' or '[' or '{' or '“' or '‘' or '\n' or '\r';
        if (previous.HasValue && !char.IsWhiteSpace(previous.Value) && !previousOpening && !startsClosing)
            value = " " + value;
        // A trailing space also handles edit controls which do not expose caret context.
        if (!next.HasValue || (!char.IsWhiteSpace(next.Value) && !",.;:!?)]}”’".Contains(next.Value))) value += " ";
        return value;
    }

    private sealed record CaretContext(bool Password, char? Previous, char? Next);

    private static IDataObject? SnapshotClipboard()
    {
        // Copy values now. Holding GetDataObject() itself across SetText can keep a delayed
        // rendering reference which no longer represents the previous clipboard contents.
        var snapshot = new DataObject();
        bool any = false;
        var original = Clipboard.GetDataObject();
        if (original is null) return snapshot;
        foreach (var format in new[] { DataFormats.UnicodeText, DataFormats.Text, DataFormats.StringFormat, DataFormats.Rtf, DataFormats.Html })
            if (original.GetDataPresent(format, false) && original.GetData(format, false) is string value)
            { snapshot.SetData(format, value); any = true; }
        if (original.GetDataPresent(DataFormats.FileDrop, false) && original.GetData(DataFormats.FileDrop, false) is string[] files)
        { snapshot.SetData(DataFormats.FileDrop, (string[])files.Clone()); any = true; }
        if (Clipboard.ContainsImage() && Clipboard.GetImage() is { } image)
        {
            var copied = image.Clone(); copied.Freeze();
            snapshot.SetImage(copied); any = true;
        }
        return any ? snapshot : null;
    }
    private static CaretContext? GetCaretContext(uint processId)
    {
        try
        {
            var focused = AutomationElement.FocusedElement;
            if (focused is null || focused.Current.ProcessId != processId) return null;
            if (focused.Current.IsPassword) return new(true, null, null);
            if (!focused.TryGetCurrentPattern(TextPattern.Pattern, out object pattern)) return null;
            var ranges = ((TextPattern)pattern).GetSelection();
            if (ranges.Length != 1) return null;
            var selected = ranges[0];
            var before = selected.Clone();
            before.MoveEndpointByRange(TextPatternRangeEndpoint.End, selected, TextPatternRangeEndpoint.Start);
            before.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, -1);
            string previous = before.GetText(2);
            var after = selected.Clone();
            after.MoveEndpointByRange(TextPatternRangeEndpoint.Start, selected, TextPatternRangeEndpoint.End);
            after.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, 1);
            string next = after.GetText(2);
            return new(false, previous.Length > 0 ? previous[^1] : null, next.Length > 0 ? next[0] : null);
        }
        catch { return null; }
    }

    private static async Task RestoreClipboardAsync(IDataObject? previous, uint expectedSequence)
    {
        try
        {
            await Task.Delay(900);
            if (NativeMethods.GetClipboardSequenceNumber() != expectedSequence) return;
            if (previous is null) Clipboard.Clear(); else Clipboard.SetDataObject(previous, true);
        }
        catch { /* Clipboard ownership or its source process may have changed. */ }
    }
}
