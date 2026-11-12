using System.Globalization;
using System.Text.RegularExpressions;

namespace Voice.Core;

/// <summary>Conservative local formatting. Ambiguous rewrites are left to the optional
/// local editor, whose response is checked before it replaces the transcript.</summary>
public static class TextCleanup
{
    private const string Time = @"\d{1,2}(?::\d{2})?\s*(?:a\.?\s*m\.?|p\.?\s*m\.?)";
    private const string Day = @"Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday";
    private static readonly TimeSpan RegexLimit = TimeSpan.FromSeconds(1);
    private static Regex Re(string pattern, RegexOptions options = RegexOptions.None) => new(pattern, options | RegexOptions.CultureInvariant, RegexLimit);

    public static string Vocabulary(string text, IReadOnlyList<VocabularyEntry> entries)
    {
        var mapping = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in entries.Take(500))
        {
            var preferred = entry.Preferred.Trim(); var heard = entry.Heard.Trim();
            if (preferred.Length == 0 || preferred.Length > 120) continue;
            mapping[preferred] = preferred;
            if (heard.Length > 0 && heard.Length <= 120) mapping[heard] = preferred;
        }
        if (mapping.Count == 0) return text;
        var pattern = @"(?<![\p{L}\p{N}_])(?:" + string.Join("|", mapping.Keys.OrderByDescending(x => x.Length).Select(Regex.Escape)) + @")(?![\p{L}\p{N}_])";
        return Re(pattern, RegexOptions.IgnoreCase).Replace(text, m => mapping[m.Value]);
    }

    public static string PreferredWords(IReadOnlyList<VocabularyEntry> entries) => string.Join(", ", entries.Select(x => x.Preferred.Trim()).Where(x => x.Length > 0).Distinct()).Truncate(700);

    public static string Apply(string text, IReadOnlyList<VocabularyEntry> entries, bool removeFillers = true)
    {
        text = Vocabulary(text, entries);
        text = ResolveExplicitCorrections(text);
        text = FormatSpoken(text);
        return Basic(text, removeFillers);
    }

    public static string Basic(string text, bool removeFillers)
    {
        text = Re(@"[\t ]+").Replace(text, " ");
        if (removeFillers)
            text = OutsideQuotes(text, part => Re(@"(?i)(?<![\p{L}\p{N}-])(?:um+|uh+|erm+)(?![\p{L}\p{N}-])[,;:]? *").Replace(part, ""));
        text = Re(@" +([,.!?;:])").Replace(text, "$1");
        text = Re(@"\bi\b").Replace(text, "I");
        text = Re(@" *\n *").Replace(text, "\n").Trim();
        if (text.Length == 0) return "";
        var first = char.ToUpper(text[0], CultureInfo.InvariantCulture);
        text = first + text[1..];
        if (char.IsLetterOrDigit(text[^1])) text += ".";
        return text;
    }

    public static string ResolveExplicitCorrections(string input)
    {
        // Deliberately do not reinterpret a quoted example as an editing command.
        if (input.IndexOfAny(['"', '“', '”']) >= 0 || Re(@"(?i)\b(?:phrase|words|said|say|saying)\b").IsMatch(input)) return input;
        var restart = Re(@"(?i)\b(?:no[,.]?\s+)?cancel (?:that|this)[,.]?\s+let me (?:restart|start again|start over)\b[,.!:;]?\s*").Matches(input);
        if (restart.Count > 0) input = input[(restart[^1].Index + restart[^1].Length)..].Trim();

        for (var iteration = 0; iteration < 8; ++iteration)
        {
            var cue = Re(@"(?i)(?:[,.;!?]\s*|\s+)(?:oh\s+)?no[,.!]?\s+(?:not\s+(?:" + Time + @"|" + Day + @")[,.;]?\s+)?(?:(?:make\s+it|(?:the\s+)?(?:reminder|alarm|meeting)\s+should\s+be\s+for|(?:it\s+)?should\s+be|I\s+mean)\s+)?(?:by\s+|at\s+|for\s+|on\s+)?(?<replacement>" + Time + "|" + Day + @")(?<tail>[^.!?]*)(?:[.!?]|$)").Match(input);
            if (!cue.Success) break;
            var prefix = input[..cue.Index];
            var replacement = cue.Groups["replacement"].Value.Trim().TrimEnd('.');
            var targets = Re(Re(@"\d").IsMatch(replacement) ? Time : @"\b(?:" + Day + @")\b", RegexOptions.IgnoreCase).Matches(prefix);
            if (targets.Count == 0) break;
            var previous = targets[^1];
            var tail = cue.Groups["tail"].Value.Trim();
            var rest = prefix[(previous.Index + previous.Length)..].Trim();
            prefix = prefix[..previous.Index] + replacement + (rest.Length > 0 ? " " + rest : "");
            if (tail.Length > 0 && !prefix.TrimEnd(' ', '.', ',', ';').EndsWith(tail, StringComparison.OrdinalIgnoreCase)) prefix += " " + tail;
            input = prefix.TrimEnd(' ', '.', ',') + ". " + input[(cue.Index + cue.Length)..].TrimStart();
            input = input.Trim();
        }
        return input;
    }

    public static string FormatSpoken(string text)
    {
        text = Re(@"(?i)\b(?:open|opening|begin)\s+quote\b[,.]?\s*").Replace(text, "“");
        text = Re(@"(?i)\s*\b(?:close|closing|end)\s+quote\b[,.]?").Replace(text, "”");
        return OutsideQuotes(text, part =>
        {
            part = Re(@"(?i)\bnew paragraph\b[,.]?\s*").Replace(part, "\n\n");
            part = Re(@"(?i)\bnew line\b[,.]?\s*").Replace(part, "\n");
            part = Re(@"(?i)\bbullet point\b[,.]?\s*").Replace(part, "\n• ");
            var names = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase) { ["one"] = 1, ["two"] = 2, ["three"] = 3, ["four"] = 4, ["five"] = 5, ["six"] = 6, ["seven"] = 7, ["eight"] = 8, ["nine"] = 9, ["ten"] = 10 };
            // Only recognise explicitly announced lists with two consecutive items.
            if (Re(@"(?i)\bnumber (?:one|1)\b").IsMatch(part) && Re(@"(?i)\bnumber (?:two|2)\b").IsMatch(part))
                part = Re(@"(?i)\bnumber (?<n>one|two|three|four|five|six|seven|eight|nine|ten|[1-9]|10)\b[,.:]?\s*")
                    .Replace(part, m => "\n" + (names.TryGetValue(m.Groups["n"].Value, out var n) ? n.ToString(CultureInfo.InvariantCulture) : m.Groups["n"].Value) + ". ");
            return part;
        });
    }

    private static string OutsideQuotes(string text, Func<string, string> transform)
    {
        var spans = Re("[\"“][^\"”]*[\"”]").Matches(text);
        if (spans.Count == 0) return transform(text);
        var result = new System.Text.StringBuilder(); var start = 0;
        foreach (Match match in spans) { result.Append(transform(text[start..match.Index])); result.Append(match.Value); start = match.Index + match.Length; }
        return result.Append(transform(text[start..])).ToString();
    }

    public static string? ValidateEdited(string edited, string original)
    {
        original = ResolveExplicitCorrections(original);
        var result = edited.Trim();
        if (result.Length == 0 || result.Length > Math.Max(original.Length * 2, original.Length + 100) || result.Contains("<|im_", StringComparison.Ordinal) ||
            Re(@"(?i)^(?:sure\b|here(?:'s| is)\b)").IsMatch(result)) return null;
        static HashSet<string> Words(string value) => Re(@"[\p{L}\p{N}]+")
            .Matches(value.ToLowerInvariant().Replace("’", "").Replace("'", "")).Select(m => m.Value).ToHashSet();
        var source = Words(original); var output = Words(result);
        var grammar = "a an the is are was were be been being to of and or but so that it its".Split(' ').ToHashSet();
        if (output.Except(source).Except(grammar).Any()) return null;
        var negatives = "not never cannot cant dont doesnt didnt wont shouldnt wouldnt couldnt isnt arent".Split(' ').ToHashSet();
        if (!source.Intersect(negatives).ToHashSet().SetEquals(output.Intersect(negatives))) return null;
        var oldNumbers = Re(@"\d+(?:[.,]\d+)*").Matches(original).Select(x => x.Value).ToHashSet();
        var newNumbers = Re(@"\d+(?:[.,]\d+)*").Matches(result).Select(x => x.Value).ToHashSet();
        if (!newNumbers.IsSubsetOf(oldNumbers)) return null;
        var repair = Re(@"(?i)\b(?:no|actually|sorry|rather|instead|scratch|cancel|restart|I mean)\b").IsMatch(original);
        if (!repair && (!oldNumbers.SetEquals(newNumbers) || result.Length < original.Length / 2)) return null;
        if (original.Contains('\n') && !result.Contains('\n')) return null;
        if (original.Contains('“') && (!result.Contains('“') || !result.Contains('”'))) return null;
        return result;
    }

    internal static string Truncate(this string text, int count) => text.Length <= count ? text : text[..count];
}
