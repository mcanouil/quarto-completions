/**
 * Emits a self-contained PowerShell completion script.
 *
 * The CLI surface is emitted as data and consumed by one generic completer, so
 * the script stays readable no matter how many commands Quarto grows. Both
 * `quarto` and `quarto.cmd` are registered, since the Windows installation puts
 * the shim on `PATH`.
 */

import type { CommandSpec, Spec } from "../spec.ts";
import { commandName, optionFlags } from "../spec.ts";
import {
  banner,
  nodes,
  oneLine,
  positionals,
  trailingIsVariadic,
  valuedOptions,
} from "./common.ts";

export function emitPwsh(spec: Spec): string {
  const all = nodes(spec);
  return `${banner(spec, "#")}

$script:QuartoCompletionSpec = @{
${all.map(nodeEntry).join("\n")}
}

# Walks the words typed so far, resolving the command path and how many
# positionals follow it. Words consumed as flag values are not positionals.
function Script:Resolve-QuartoNode {
  param([string[]]$Words)

  $path = @()
  $position = 0
  $skip = $false
  # Values is keyed by every flag that consumes the next word, so its key set
  # doubles as the valued-flag list.
  $valued = $script:QuartoCompletionSpec[''].Values

  foreach ($word in $Words) {
    if ($skip) { $skip = $false; continue }
    if ($word.StartsWith('-')) {
      if ($valued.ContainsKey($word)) { $skip = $true }
      continue
    }
    $candidate = (($path + $word) -join ' ')
    if ($script:QuartoCompletionSpec.ContainsKey($candidate)) {
      $path += $word
      $position = 0
      $valued = $script:QuartoCompletionSpec[$candidate].Values
      continue
    }
    $position++
  }

  return [pscustomobject]@{
    Node     = $script:QuartoCompletionSpec[($path -join ' ')]
    Position = $position
  }
}

function Script:New-QuartoResult {
  param([string]$Text, [string]$Tooltip)

  [System.Management.Automation.CompletionResult]::new(
    $Text,
    $Text,
    'ParameterValue',
    $(if ([string]::IsNullOrWhiteSpace($Tooltip)) { $Text } else { $Tooltip })
  )
}

$script:QuartoCompleter = {
  param($wordToComplete, $commandAst, $cursorPosition)

  $words = @($commandAst.CommandElements | Select-Object -Skip 1 | ForEach-Object { $_.ToString() })
  # Drop the partial word the user is typing. A range ending at -1 would wrap
  # around and repeat the whole array, so the single-word case is explicit.
  if ($words.Count -gt 0 -and $words[-1] -eq $wordToComplete) {
    if ($words.Count -gt 1) {
      $words = @($words[0..($words.Count - 2)])
    }
    else {
      $words = @()
    }
  }

  $resolved = Script:Resolve-QuartoNode -Words $words
  $node = $resolved.Node
  if ($null -eq $node) { return }

  # A flag expecting a value wins over commands and positionals.
  $previous = if ($words.Count -gt 0) { $words[-1] } else { '' }
  if ($node.Values.ContainsKey($previous)) {
    return $node.Values[$previous] |
      Where-Object { $_ -like "$wordToComplete*" } |
      ForEach-Object { Script:New-QuartoResult -Text $_ }
  }

  if ($wordToComplete.StartsWith('-')) {
    return $node.Options.GetEnumerator() |
      Where-Object { $_.Key -like "$wordToComplete*" } |
      Sort-Object Key |
      ForEach-Object { Script:New-QuartoResult -Text $_.Key -Tooltip $_.Value }
  }

  $results = @()
  if ($resolved.Position -eq 0) {
    $results += $node.Commands.GetEnumerator() |
      Where-Object { $_.Key -like "$wordToComplete*" } |
      Sort-Object Key |
      ForEach-Object { Script:New-QuartoResult -Text $_.Key -Tooltip $_.Value }
  }

  $slot = $resolved.Position
  if ($node.Variadic -and $slot -ge $node.Positional.Count) {
    $slot = $node.Positional.Count - 1
  }
  if ($slot -ge 0 -and $slot -lt $node.Positional.Count) {
    $results += $node.Positional[$slot] |
      Where-Object { $_ -like "$wordToComplete*" } |
      ForEach-Object { Script:New-QuartoResult -Text $_ }
  }
  return $results
}

Register-ArgumentCompleter -Native -CommandName quarto -ScriptBlock $script:QuartoCompleter
Register-ArgumentCompleter -Native -CommandName quarto.cmd -ScriptBlock $script:QuartoCompleter
`;
}

function nodeEntry(command: CommandSpec): string {
  const key = command.path.join(" ");

  const options = command.options.flatMap((option) =>
    optionFlags(option).map((flag) => `      ${quote(flag)} = ${quote(oneLine(option.description))}`)
  );

  const commands = command.commands.map((child) =>
    `      ${quote(commandName(child))} = ${quote(oneLine(child.description))}`
  );

  // Keyed by every flag that consumes a value, not only the enums: a flag
  // whose candidates are unknown maps to an empty list, so the completer
  // returns nothing and PowerShell falls back to path completion rather than
  // offering subcommands as the flag's value.
  const values = valuedOptions(command)
    .flatMap((option) =>
      optionFlags(option).map((flag) => `      ${quote(flag)} = @(${enumCandidates(option)})`)
    );

  // Keyed by index rather than emitted as a nested array, which PowerShell
  // would flatten. File and directory positionals are left as empty slots on
  // purpose: PowerShell falls back to path completion when a native completer
  // returns nothing.
  const slots = positionals(command).map((arg, index) =>
    `      ${index} = @(${enumCandidates(arg)})`
  );

  return `  ${quote(key)} = @{
    Options = @{
${options.join("\n")}
    }
    Commands = @{
${commands.join("\n")}
    }
    Values = @{
${values.join("\n")}
    }
    Positional = @{
${slots.join("\n")}
    }
    Variadic = $${trailingIsVariadic(command)}
  }`;
}

/** Quoted candidate list for a flag or slot; empty when nothing is known. */
function enumCandidates(spec: { kind: string; values?: string[] }): string {
  return (spec.kind === "enum" ? spec.values ?? [] : []).map(quote).join(", ");
}

function quote(text: string): string {
  return `'${text.replace(/'/g, "''")}'`;
}
