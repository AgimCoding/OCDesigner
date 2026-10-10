#requires -Version 5.1
<#
    OC Designer - editeur visuel du menu de demarrage OpenCore (Windows, PowerShell + WPF)

    Lancement : double-clic sur OCDesigner.bat
    Options   : -EfiPath "Z:\EFI\OC"   ouvre directement ce dossier
                -NoGui                 charge uniquement les fonctions (tests)
                -SelfTest <dossier>    lance un auto-test avec captures (utiliser sur une COPIE de l'EFI)

    Principes :
      - seules les cles deja presentes dans config.plist sont modifiees (le schema de votre version d'OpenCore est respecte) ;
      - la mise en forme du fichier est conservee (indentation, fins de ligne) ;
      - toute ecriture est precedee d'une sauvegarde dans %LOCALAPPDATA%\OCDesigner\Backups.
#>
param(
    [string]$EfiPath,
    [switch]$NoGui,
    [string]$SelfTest
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------
#  Constantes
# ---------------------------------------------------------------------------------------------
$script:AppName   = 'OC Designer'
$script:AppVer    = '1.1'
$script:GuidUi    = '4D1EDE05-38C7-4A6A-9CC6-4BCCA8B38C14'
$script:GuidApple = '7C436110-AB2A-4BBB-A880-FE41995C9F82'

if ($env:OCD_HOME)          { $script:AppDir = $env:OCD_HOME }
elseif ($env:LOCALAPPDATA)  { $script:AppDir = Join-Path $env:LOCALAPPDATA 'OCDesigner' }
else                        { $script:AppDir = Join-Path ([IO.Path]::GetTempPath()) 'OCDesigner' }
$script:BackupRoot   = Join-Path $script:AppDir 'Backups'
$script:SettingsFile = Join-Path $script:AppDir 'settings.json'
$script:LogFile      = Join-Path $script:AppDir 'ocdesigner.log'
$script:MaxAutoBackups = 60

# Cles de config.plist gerees par l'editeur : Id -> chemin
$script:FieldDefs = [ordered]@{
    PickerMode           = @('Misc', 'Boot', 'PickerMode')
    PickerVariant        = @('Misc', 'Boot', 'PickerVariant')
    PickerAttributes     = @('Misc', 'Boot', 'PickerAttributes')
    ConsoleAttributes    = @('Misc', 'Boot', 'ConsoleAttributes')
    ShowPicker           = @('Misc', 'Boot', 'ShowPicker')
    Timeout              = @('Misc', 'Boot', 'Timeout')
    HideAuxiliary        = @('Misc', 'Boot', 'HideAuxiliary')
    PollAppleHotKeys     = @('Misc', 'Boot', 'PollAppleHotKeys')
    PickerAudioAssist    = @('Misc', 'Boot', 'PickerAudioAssist')
    TakeoffDelay         = @('Misc', 'Boot', 'TakeoffDelay')
    HibernateSkipsPicker = @('Misc', 'Boot', 'HibernateSkipsPicker')
    AllowSetDefault      = @('Misc', 'Security', 'AllowSetDefault')
    UIScale              = @('UEFI', 'Output', 'UIScale')
    TextRenderer         = @('UEFI', 'Output', 'TextRenderer')
    Resolution           = @('UEFI', 'Output', 'Resolution')
}

# Bits connus de PickerAttributes
$script:AttrBits = @(0x1, 0x2, 0x4, 0x8, 0x10, 0x40, 0x80, 0x100, 0x200)

# Couleurs EFI (ConsoleAttributes)
$script:EfiColors = @('#000000', '#0000AA', '#00AA00', '#00AAAA', '#AA0000', '#AA00AA', '#AA5500', '#AAAAAA',
                      '#555555', '#5555FF', '#55FF55', '#55FFFF', '#FF5555', '#FF55FF', '#FFFF55', '#FFFFFF')

# Icones 128x128 remplacables d'un theme OpenCanopy
$script:IconSlots = @('Apple', 'AppleRecv', 'AppleTM', 'Windows', 'HardDrive', 'ExtHardDrive',
                      'OpticalDrive', 'Other', 'ResetNVRAM', 'Shell', 'Tool')
$script:SystemIcons = @('Background', 'Cursor', 'Selected', 'Selector', 'SetDefault', 'Left', 'Right',
                        'ShutDown', 'Restart', 'BtnFocus', 'Dot', 'Enter', 'Lock', 'Password')

# ---------------------------------------------------------------------------------------------
#  Journal
# ---------------------------------------------------------------------------------------------
function Write-Log([string]$Message) {
    try {
        if (-not (Test-Path -LiteralPath $script:AppDir)) { [void](New-Item -ItemType Directory -Path $script:AppDir -Force) }
        $line = '{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
        [IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# ---------------------------------------------------------------------------------------------
#  Lecture / ecriture du plist (XML avec conservation de la mise en forme)
# ---------------------------------------------------------------------------------------------
function ConvertTo-PlistText($Doc) {
    $s = $Doc.OuterXml
    # .NET ajoute "[]" au DOCTYPE et un espace dans les balises vides : on revient au format Apple.
    $s = [regex]::Replace($s, '(<!DOCTYPE[^>\[]*?)\s*\[\s*\]>', '$1>')
    $s = [regex]::Replace($s, '<([A-Za-z]+) />', '<$1/>')
    return $s
}

function Read-PlistFile([string]$Path) {
    $bytes  = [IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $enc    = New-Object System.Text.UTF8Encoding($false)
    if ($hasBom) { $text = $enc.GetString($bytes, 3, $bytes.Length - 3) } else { $text = $enc.GetString($bytes) }
    $crlf = $text.Contains("`r`n")
    $norm = $text.Replace("`r`n", "`n")

    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.XmlResolver = $null
    $doc.LoadXml($norm)
    if (-not $doc.DocumentElement -or $doc.DocumentElement.LocalName -ne 'plist') { throw 'Not a plist file.' }

    $info = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        Path     = $Path
        Doc      = $doc
        HasBom   = $hasBom
        Crlf     = $crlf
        Lossless = ((ConvertTo-PlistText $doc) -ceq $norm)
        Stamp    = $info.LastWriteTimeUtc
        Length   = $info.Length
    }
}

function Get-PlistBytes($Plist) {
    $text = ConvertTo-PlistText $Plist.Doc
    # controle : le texte produit doit rester un XML valide
    $check = New-Object System.Xml.XmlDocument
    $check.XmlResolver = $null
    $check.LoadXml($text)
    if ($Plist.Crlf) { $text = $text.Replace("`n", "`r`n") }
    $enc  = New-Object System.Text.UTF8Encoding($false)
    $body = $enc.GetBytes($text)
    if ($Plist.HasBom) {
        $all = New-Object byte[] ($body.Length + 3)
        $all[0] = 0xEF; $all[1] = 0xBB; $all[2] = 0xBF
        [Array]::Copy($body, 0, $all, 3, $body.Length)
        return ,$all
    }
    return ,$body
}

function Get-PlistRootDict($Doc) {
    $n = $Doc.DocumentElement.FirstChild
    while ($n) {
        if ($n.NodeType -eq [System.Xml.XmlNodeType]::Element -and $n.LocalName -eq 'dict') { return $n }
        $n = $n.NextSibling
    }
    return $null
}

function Get-PlistChild($Dict, [string]$Key) {
    if (-not $Dict) { return $null }
    $n = $Dict.FirstChild
    while ($n) {
        if ($n.NodeType -eq [System.Xml.XmlNodeType]::Element -and $n.LocalName -eq 'key' -and $n.InnerText -ceq $Key) {
            $v = $n.NextSibling
            while ($v -and $v.NodeType -ne [System.Xml.XmlNodeType]::Element) { $v = $v.NextSibling }
            return $v
        }
        $n = $n.NextSibling
    }
    return $null
}

function Get-PlistNode($Doc, [string[]]$Path) {
    $cur = Get-PlistRootDict $Doc
    foreach ($k in $Path) {
        $cur = Get-PlistChild $cur $k
        if (-not $cur) { return $null }
    }
    return $cur
}

function Get-PlistValue($Node) {
    if (-not $Node) { return $null }
    $name = $Node.LocalName
    if ($name -eq 'true')    { return $true }
    if ($name -eq 'false')   { return $false }
    if ($name -eq 'integer') { return [int64]($Node.InnerText.Trim()) }
    if ($name -eq 'string')  { return [string]$Node.InnerText }
    if ($name -eq 'data')    { return ,([Convert]::FromBase64String(($Node.InnerText -replace '\s', ''))) }
    return $null
}

function Set-PlistValue($Node, $Value) {
    $doc  = $Node.OwnerDocument
    $name = $Node.LocalName
    if ($name -eq 'true' -or $name -eq 'false') {
        if ($Value) { $want = 'true' } else { $want = 'false' }
        if ($want -ne $name) {
            $new = $doc.CreateElement($want)
            [void]$Node.ParentNode.ReplaceChild($new, $Node)
            return $new
        }
        return $Node
    }
    if ($name -eq 'integer') { $Node.InnerText = ([int64]$Value).ToString([Globalization.CultureInfo]::InvariantCulture); return $Node }
    if ($name -eq 'string')  { $Node.InnerText = [string]$Value; return $Node }
    if ($name -eq 'data')    { $Node.InnerText = [Convert]::ToBase64String([byte[]]$Value); return $Node }
    throw "Unsupported plist type: $name"
}

function Test-XmlSpace($Node) {
    if (-not $Node) { return $false }
    return ($Node.NodeType -eq [System.Xml.XmlNodeType]::Whitespace -or $Node.NodeType -eq [System.Xml.XmlNodeType]::SignificantWhitespace)
}

function Get-NodeIndent($Node) {
    $p = $Node.PreviousSibling
    if (Test-XmlSpace $p) {
        $t = [string]$p.Value
        $i = $t.LastIndexOf("`n")
        if ($i -ge 0) { return $t.Substring($i + 1) }
        return $t
    }
    return ''
}

# Ajoute des noeuds a la fin d'un <dict> ou d'un <array>, chacun sur sa ligne, avec la bonne indentation.
function Add-PlistNodes($Container, [object[]]$Nodes) {
    $doc    = $Container.OwnerDocument
    $indent = Get-NodeIndent $Container
    $child  = $indent + "`t"
    $first  = $Container.FirstChild
    if ((Test-XmlSpace $first) -and $first.NextSibling) {
        $t = [string]$first.Value
        $i = $t.LastIndexOf("`n")
        if ($i -ge 0) { $child = $t.Substring($i + 1) }
    }
    $last = $Container.LastChild
    if (-not $last) {
        $Container.IsEmpty = $false
        foreach ($n in $Nodes) {
            [void]$Container.AppendChild($doc.CreateWhitespace("`n" + $child))
            [void]$Container.AppendChild($n)
        }
        [void]$Container.AppendChild($doc.CreateWhitespace("`n" + $indent))
        return
    }
    if (Test-XmlSpace $last) {
        foreach ($n in $Nodes) {
            [void]$Container.InsertBefore($doc.CreateWhitespace("`n" + $child), $last)
            [void]$Container.InsertBefore($n, $last)
        }
        return
    }
    foreach ($n in $Nodes) {
        [void]$Container.AppendChild($doc.CreateWhitespace("`n" + $child))
        [void]$Container.AppendChild($n)
    }
    [void]$Container.AppendChild($doc.CreateWhitespace("`n" + $indent))
}

function New-PlistNode($Doc, [string]$Type, [string]$Text) {
    $n = $Doc.CreateElement($Type)
    if ($Type -ne 'true' -and $Type -ne 'false' -and $Type -ne 'dict' -and $Type -ne 'array') {
        if ($Text) { $n.InnerText = $Text } else { $n.IsEmpty = $false }
    }
    return $n
}

# Retourne (en le creant si besoin) l'element associe a une cle d'un dict.
function Get-OrAddPlistChild($Dict, [string]$Key, [string]$Type, [string]$Text) {
    $existing = Get-PlistChild $Dict $Key
    if ($existing) { return $existing }
    $doc = $Dict.OwnerDocument
    $k = New-PlistNode $doc 'key' $Key
    $v = New-PlistNode $doc $Type $Text
    Add-PlistNodes $Dict @($k, $v)
    return $v
}

function Get-PlistArrayStrings($Array) {
    $out = @()
    if (-not $Array) { return $out }
    $n = $Array.FirstChild
    while ($n) {
        if ($n.NodeType -eq [System.Xml.XmlNodeType]::Element -and $n.LocalName -eq 'string') { $out += [string]$n.InnerText }
        $n = $n.NextSibling
    }
    return $out
}

# S'assure qu'une variable figure dans NVRAM > Delete (sinon OpenCore n'ecrase pas la valeur deja en NVRAM).
function Add-NvramDeleteEntry($Doc, [string]$Guid, [string]$Name) {
    $delete = Get-PlistNode $Doc @('NVRAM', 'Delete')
    if (-not $delete -or $delete.LocalName -ne 'dict') { return $false }
    $arr = Get-OrAddPlistChild $delete $Guid 'array' ''
    if ((Get-PlistArrayStrings $arr) -ccontains $Name) { return $false }
    Add-PlistNodes $arr @((New-PlistNode $Doc 'string' $Name))
    return $true
}

# ---------------------------------------------------------------------------------------------
#  Etat (valeurs lues dans config.plist)
# ---------------------------------------------------------------------------------------------
function ConvertTo-HexColor([byte[]]$Bgra) {
    if (-not $Bgra -or $Bgra.Length -lt 3) { return $null }
    return ('#{0:X2}{1:X2}{2:X2}' -f $Bgra[2], $Bgra[1], $Bgra[0])
}

function ConvertFrom-HexColor([string]$Hex) {
    if ($Hex -notmatch '^#?([0-9A-Fa-f]{6})$') { throw "Invalid colour: $Hex" }
    $h = $Matches[1]
    $r = [Convert]::ToByte($h.Substring(0, 2), 16)
    $g = [Convert]::ToByte($h.Substring(2, 2), 16)
    $b = [Convert]::ToByte($h.Substring(4, 2), 16)
    return ,([byte[]]@($b, $g, $r, 0))
}

function Test-VerboseArg([string]$BootArgs) {
    if (-not $BootArgs) { return $false }
    return (($BootArgs -split '\s+') -ccontains '-v')
}

function Set-VerboseArg([string]$BootArgs, [bool]$Enabled) {
    $tokens = @()
    if ($BootArgs) { $tokens = @($BootArgs -split '\s+' | Where-Object { $_ -ne '' }) }
    $tokens = @($tokens | Where-Object { $_ -cne '-v' })
    if ($Enabled) { $tokens = @('-v') + $tokens }
    return ($tokens -join ' ')
}

function Read-State($Plist) {
    $state = @{}
    foreach ($id in $script:FieldDefs.Keys) {
        $state[$id] = Get-PlistValue (Get-PlistNode $Plist.Doc $script:FieldDefs[$id])
    }
    $bg = Get-PlistValue (Get-PlistNode $Plist.Doc @('NVRAM', 'Add', $script:GuidUi, 'DefaultBackgroundColor'))
    $state['BgColor'] = ConvertTo-HexColor $bg
    $bootArgsNode = Get-PlistNode $Plist.Doc @('NVRAM', 'Add', $script:GuidApple, 'boot-args')
    if ($bootArgsNode -and $bootArgsNode.LocalName -eq 'string') {
        $state['Verbose'] = Test-VerboseArg ([string]$bootArgsNode.InnerText)
    } else {
        $state['Verbose'] = $null
    }
    return $state
}

function Copy-State($State) {
    $c = @{}
    foreach ($k in $State.Keys) { $c[$k] = $State[$k] }
    return $c
}

function Get-StateChanges($Orig, $State) {
    $changed = @()
    foreach ($k in $State.Keys) {
        $a = $Orig[$k]; $b = $State[$k]
        if ($null -eq $a -and $null -eq $b) { continue }
        if ($null -eq $a -or $null -eq $b) { $changed += $k; continue }
        if ($a -is [string] -or $b -is [string]) { if ([string]$a -cne [string]$b) { $changed += $k } }
        elseif ($a -ne $b) { $changed += $k }
    }
    return $changed
}

# ---------------------------------------------------------------------------------------------
#  Pilotes UEFI (OpenCanopy)
# ---------------------------------------------------------------------------------------------
function Get-DriverEntries($Doc) {
    $list = @()
    $arr = Get-PlistNode $Doc @('UEFI', 'Drivers')
    if (-not $arr) { return $list }
    $n = $arr.FirstChild
    while ($n) {
        if ($n.NodeType -eq [System.Xml.XmlNodeType]::Element) {
            if ($n.LocalName -eq 'dict') {
                $p = Get-PlistValue (Get-PlistChild $n 'Path')
                $e = Get-PlistValue (Get-PlistChild $n 'Enabled')
                $list += [pscustomobject]@{ Node = $n; Path = [string]$p; Enabled = [bool]$e; IsDict = $true }
            } elseif ($n.LocalName -eq 'string') {
                $txt = [string]$n.InnerText
                $list += [pscustomobject]@{ Node = $n; Path = $txt.TrimStart('#'); Enabled = (-not $txt.StartsWith('#')); IsDict = $false }
            }
        }
        $n = $n.NextSibling
    }
    return $list
}

function Get-CanopyStatus([string]$EfiOc, $Doc) {
    $file  = Test-Path -LiteralPath (Join-Path $EfiOc 'Drivers\OpenCanopy.efi')
    $entry = @(Get-DriverEntries $Doc | Where-Object { $_.Path -ieq 'OpenCanopy.efi' })
    $declared = ($entry.Count -gt 0)
    $enabled  = ($declared -and $entry[0].Enabled)
    $res = (Test-Path -LiteralPath (Join-Path $EfiOc 'Resources\Image')) -and
           (Test-Path -LiteralPath (Join-Path $EfiOc 'Resources\Label')) -and
           (Test-Path -LiteralPath (Join-Path $EfiOc 'Resources\Font'))
    return [pscustomobject]@{ File = $file; Declared = $declared; Enabled = $enabled; Resources = $res }
}

# Declare (ou reactive) OpenCanopy.efi dans UEFI > Drivers en reprenant le format des entrees existantes.
function Enable-CanopyDriver($Doc) {
    $arr = Get-PlistNode $Doc @('UEFI', 'Drivers')
    if (-not $arr) { return $false }
    $entries = @(Get-DriverEntries $Doc)
    $mine = @($entries | Where-Object { $_.Path -ieq 'OpenCanopy.efi' })
    if ($mine.Count -gt 0) {
        if ($mine[0].Enabled) { return $false }
        if ($mine[0].IsDict) { [void](Set-PlistValue (Get-PlistChild $mine[0].Node 'Enabled') $true) }
        else { $mine[0].Node.InnerText = 'OpenCanopy.efi' }
        return $true
    }
    $template = @($entries | Where-Object { $_.IsDict })
    if ($template.Count -gt 0) {
        $clone = $template[0].Node.CloneNode($true)
        foreach ($k in @('Path', 'Comment')) {
            $node = Get-PlistChild $clone $k
            if ($node) { [void](Set-PlistValue $node 'OpenCanopy.efi') }
        }
        $node = Get-PlistChild $clone 'Arguments'; if ($node) { [void](Set-PlistValue $node '') }
        $node = Get-PlistChild $clone 'Enabled';   if ($node) { [void](Set-PlistValue $node $true) }
        $node = Get-PlistChild $clone 'LoadEarly'; if ($node) { [void](Set-PlistValue $node $false) }
        Add-PlistNodes $arr @($clone)
        return $true
    }
    if ($entries.Count -gt 0) {
        Add-PlistNodes $arr @((New-PlistNode $Doc 'string' 'OpenCanopy.efi'))
        return $true
    }
    # liste vide : format moderne (OpenCore 0.7.3+)
    $dict = $Doc.CreateElement('dict')
    Add-PlistNodes $arr @($dict)
    $pairs = @(
        @('Arguments', 'string', ''), @('Comment', 'string', 'OpenCanopy.efi'), @('Enabled', 'true', ''),
        @('LoadEarly', 'false', ''), @('Path', 'string', 'OpenCanopy.efi')
    )
    foreach ($p in $pairs) {
        Add-PlistNodes $dict @((New-PlistNode $Doc 'key' $p[0]), (New-PlistNode $Doc $p[1] $p[2]))
    }
    return $true
}

# ---------------------------------------------------------------------------------------------
#  Application de l'etat dans le document
# ---------------------------------------------------------------------------------------------
function Set-StateInDoc($Plist, $Orig, $State, [string]$EfiOc) {
    $doc = $Plist.Doc
    $changes = @(Get-StateChanges $Orig $State)
    $notes = @()
    foreach ($id in $changes) {
        if ($script:FieldDefs.Contains($id)) {
            $node = Get-PlistNode $doc $script:FieldDefs[$id]
            if ($node) { [void](Set-PlistValue $node $State[$id]) }
            continue
        }
        if ($id -eq 'BgColor' -and $State['BgColor']) {
            $add = Get-PlistNode $doc @('NVRAM', 'Add')
            if ($add) {
                $guidDict = Get-OrAddPlistChild $add $script:GuidUi 'dict' ''
                $node = Get-OrAddPlistChild $guidDict 'DefaultBackgroundColor' 'data' ''
                [void](Set-PlistValue $node (ConvertFrom-HexColor $State['BgColor']))
                if (Add-NvramDeleteEntry $doc $script:GuidUi 'DefaultBackgroundColor') { $notes += 'nvram-delete' }
            }
            continue
        }
        if ($id -eq 'Verbose') {
            $node = Get-PlistNode $doc @('NVRAM', 'Add', $script:GuidApple, 'boot-args')
            if ($node -and $node.LocalName -eq 'string') {
                [void](Set-PlistValue $node (Set-VerboseArg ([string]$node.InnerText) ([bool]$State['Verbose'])))
                if (Add-NvramDeleteEntry $doc $script:GuidApple 'boot-args') { $notes += 'nvram-delete' }
            }
            continue
        }
    }
    # Menu graphique : le pilote OpenCanopy doit etre declare s'il est present sur le disque.
    if ($State['PickerMode'] -eq 'External' -and $EfiOc) {
        $st = Get-CanopyStatus $EfiOc $doc
        if ($st.File -and -not $st.Enabled) {
            if (Enable-CanopyDriver $doc) { $notes += 'canopy-driver' }
        }
    }
    return $notes
}

# ---------------------------------------------------------------------------------------------
#  Sauvegardes
# ---------------------------------------------------------------------------------------------
function Get-DirSize([string]$Path) {
    $sum = 0
    if (Test-Path -LiteralPath $Path) {
        foreach ($f in (Get-ChildItem -LiteralPath $Path -Recurse -File -Force)) { $sum += $f.Length }
    }
    return [int64]$sum
}

function New-BackupId([string]$Suffix) {
    if (-not (Test-Path -LiteralPath $script:BackupRoot)) { [void](New-Item -ItemType Directory -Path $script:BackupRoot -Force) }
    $base = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $id = "$base-$Suffix"; $i = 1
    while (Test-Path -LiteralPath (Join-Path $script:BackupRoot $id)) { $i++; $id = "$base-$i-$Suffix" }
    return $id
}

# Sauvegarde ciblee : copie les fichiers indiques (chemins relatifs a EFI\OC). Les fichiers qui
# n'existent pas encore sont notes "absents" : une restauration les supprimera (annulation complete).
function New-Backup([string]$EfiOc, [string]$Reason, [string[]]$RelFiles) {
    $id  = New-BackupId 'auto'
    $dir = Join-Path $script:BackupRoot $id
    [void](New-Item -ItemType Directory -Path (Join-Path $dir 'files') -Force)
    $present = @(); $absent = @()
    foreach ($rel in $RelFiles) {
        $src = Join-Path $EfiOc $rel
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            $dst = Join-Path (Join-Path $dir 'files') $rel
            $parent = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
            Copy-Item -LiteralPath $src -Destination $dst -Force
            $present += $rel
        } else {
            $absent += $rel
        }
    }
    $meta = [ordered]@{
        Id = $id; Kind = 'auto'; Created = (Get-Date).ToString('s'); Reason = $Reason; EfiOc = $EfiOc
        Files = $present; Absent = $absent
    }
    [IO.File]::WriteAllText((Join-Path $dir 'backup.json'), ($meta | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    Remove-OldBackups
    return $id
}

# Sauvegarde complete : archive zip de tout le dossier EFI\OC.
function New-FullBackup([string]$EfiOc, [string]$Reason) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $id  = New-BackupId 'full'
    $dir = Join-Path $script:BackupRoot $id
    [void](New-Item -ItemType Directory -Path $dir -Force)
    [System.IO.Compression.ZipFile]::CreateFromDirectory($EfiOc, (Join-Path $dir 'OC.zip'))
    $meta = [ordered]@{
        Id = $id; Kind = 'full'; Created = (Get-Date).ToString('s'); Reason = $Reason; EfiOc = $EfiOc
        Files = @(); Absent = @()
    }
    [IO.File]::WriteAllText((Join-Path $dir 'backup.json'), ($meta | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    return $id
}

function Get-Backups {
    $list = @()
    if (-not (Test-Path -LiteralPath $script:BackupRoot)) { return $list }
    foreach ($d in (Get-ChildItem -LiteralPath $script:BackupRoot -Directory | Sort-Object Name -Descending)) {
        $metaFile = Join-Path $d.FullName 'backup.json'
        if (-not (Test-Path -LiteralPath $metaFile)) { continue }
        try { $m = Get-Content -LiteralPath $metaFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        $list += [pscustomobject]@{
            Id = [string]$m.Id; Kind = [string]$m.Kind; Created = [string]$m.Created; Reason = [string]$m.Reason
            EfiOc = [string]$m.EfiOc; Files = @($m.Files); Absent = @($m.Absent)
            Path = $d.FullName; Size = (Get-DirSize $d.FullName)
        }
    }
    return $list
}

function Remove-Backup([string]$Id) {
    if ($Id -notmatch '^[0-9A-Za-z\-]+$') { throw "Invalid backup id: $Id" }
    $dir = Join-Path $script:BackupRoot $Id
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
}

function Remove-OldBackups {
    $auto = @(Get-Backups | Where-Object { $_.Kind -eq 'auto' })
    if ($auto.Count -le $script:MaxAutoBackups) { return }
    foreach ($b in ($auto | Select-Object -Skip $script:MaxAutoBackups)) { Remove-Backup $b.Id }
}

# Restaure une sauvegarde dans le dossier EFI\OC indique. L'etat actuel est sauvegarde juste avant.
function Restore-Backup([string]$Id, [string]$EfiOc) {
    $b = @(Get-Backups | Where-Object { $_.Id -eq $Id })
    if ($b.Count -eq 0) { throw "Backup not found: $Id" }
    $b = $b[0]
    if ($b.Kind -eq 'full') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $safety = New-FullBackup $EfiOc 'before-restore'
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ocd-restore-' + [Guid]::NewGuid().ToString('N'))
        try {
            [System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $b.Path 'OC.zip'), $tmp)
            foreach ($f in (Get-ChildItem -LiteralPath $tmp -Recurse -File -Force)) {
                $rel = $f.FullName.Substring($tmp.Length).TrimStart('\', '/')
                $dst = Join-Path $EfiOc $rel
                $parent = Split-Path -Parent $dst
                if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
                Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
            }
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
        }
        return $safety
    }
    $all = @($b.Files) + @($b.Absent)
    $safety = New-Backup $EfiOc 'before-restore' $all
    foreach ($rel in $b.Files) {
        $dst = Join-Path $EfiOc $rel
        $parent = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
        Copy-Item -LiteralPath (Join-Path (Join-Path $b.Path 'files') $rel) -Destination $dst -Force
    }
    foreach ($rel in $b.Absent) {
        $dst = Join-Path $EfiOc $rel
        if (Test-Path -LiteralPath $dst -PathType Leaf) {
            Remove-Item -LiteralPath $dst -Force
            $parent = Split-Path -Parent $dst
            while ($parent -and ($parent.Length -gt $EfiOc.Length) -and (Test-Path -LiteralPath $parent) -and
                   @(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0) {
                Remove-Item -LiteralPath $parent -Force
                $parent = Split-Path -Parent $parent
            }
        }
    }
    return $safety
}

# ---------------------------------------------------------------------------------------------
#  Enregistrement de config.plist
# ---------------------------------------------------------------------------------------------
function Test-PlistChangedOnDisk($Plist) {
    $info = Get-Item -LiteralPath $Plist.Path
    return ($info.LastWriteTimeUtc -ne $Plist.Stamp -or $info.Length -ne $Plist.Length)
}

function Save-Config($Plist, $Orig, $State, [string]$EfiOc) {
    if (Test-PlistChangedOnDisk $Plist) { throw 'OCD_CHANGED_ON_DISK' }
    $notes = @(Set-StateInDoc $Plist $Orig $State $EfiOc)
    $bytes = Get-PlistBytes $Plist
    $backupId = New-Backup $EfiOc 'save' @('config.plist')
    [IO.File]::WriteAllBytes($Plist.Path, $bytes)
    # relecture de controle
    $written = [IO.File]::ReadAllBytes($Plist.Path)
    $same = ($written.Length -eq $bytes.Length)
    if ($same) { for ($i = 0; $i -lt $bytes.Length; $i++) { if ($written[$i] -ne $bytes[$i]) { $same = $false; break } } }
    if (-not $same) {
        Copy-Item -LiteralPath (Join-Path (Join-Path (Join-Path $script:BackupRoot $backupId) 'files') 'config.plist') -Destination $Plist.Path -Force
        throw 'Write verification failed; the previous config.plist has been restored.'
    }
    return [pscustomobject]@{ BackupId = $backupId; Notes = $notes }
}

# ---------------------------------------------------------------------------------------------
#  Fichiers .icns (conteneur de PNG : ic07 = 1x, ic13 = 2x)
# ---------------------------------------------------------------------------------------------
function Read-BigEndianInt([byte[]]$Bytes, [int]$Offset) {
    return ([int64]$Bytes[$Offset] -shl 24) -bor ([int64]$Bytes[$Offset + 1] -shl 16) -bor ([int64]$Bytes[$Offset + 2] -shl 8) -bor [int64]$Bytes[$Offset + 3]
}

function Read-Icns([string]$Path) {
    return (Read-IcnsBytes ([IO.File]::ReadAllBytes($Path)))
}

function Read-IcnsBytes([byte[]]$d) {
    $chunks = @{}
    if (-not $d) { return $chunks }
    if ($d.Length -lt 8 -or [Text.Encoding]::ASCII.GetString($d, 0, 4) -ne 'icns') { return $chunks }
    $pos = 8
    while ($pos + 8 -le $d.Length) {
        $type = [Text.Encoding]::ASCII.GetString($d, $pos, 4)
        $len  = [int](Read-BigEndianInt $d ($pos + 4))
        if ($len -lt 8 -or $pos + $len -gt $d.Length) { break }
        $body = New-Object byte[] ($len - 8)
        [Array]::Copy($d, $pos + 8, $body, 0, $len - 8)
        $chunks[$type] = $body
        $pos += $len
    }
    return $chunks
}

function Test-PngBytes([byte[]]$Bytes) {
    return ($Bytes -and $Bytes.Length -gt 24 -and $Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47)
}

function Get-PngSize([byte[]]$Bytes) {
    if (-not (Test-PngBytes $Bytes)) { return $null }
    return [pscustomobject]@{ Width = [int](Read-BigEndianInt $Bytes 16); Height = [int](Read-BigEndianInt $Bytes 20) }
}

# Retourne le PNG d'un .icns pour l'echelle demandee (1 ou 2), ou $null.
function Get-IcnsPng([string]$Path, [int]$Scale) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $c = Read-Icns $Path
    if ($Scale -ge 2) { $order = @('ic13', 'ic07') } else { $order = @('ic07', 'ic13') }
    foreach ($t in $order) { if ($c.ContainsKey($t) -and (Test-PngBytes $c[$t])) { return ,$c[$t] } }
    foreach ($t in $c.Keys) { if (Test-PngBytes $c[$t]) { return ,$c[$t] } }
    return $null
}

function New-IcnsBytes([byte[]]$Png1x, [byte[]]$Png2x) {
    if (-not (Test-PngBytes $Png1x) -or -not (Test-PngBytes $Png2x)) { throw 'New-IcnsBytes expects two PNG images.' }
    $total = 8 + 8 + $Png1x.Length + 8 + $Png2x.Length
    $ms = New-Object System.IO.MemoryStream
    $w = {
        param($stream, [string]$tag, [int]$len)
        $b = [Text.Encoding]::ASCII.GetBytes($tag)
        $stream.Write($b, 0, 4)
        $stream.WriteByte(($len -shr 24) -band 0xFF); $stream.WriteByte(($len -shr 16) -band 0xFF)
        $stream.WriteByte(($len -shr 8) -band 0xFF);  $stream.WriteByte($len -band 0xFF)
    }
    & $w $ms 'icns' $total
    & $w $ms 'ic07' (8 + $Png1x.Length); $ms.Write($Png1x, 0, $Png1x.Length)
    & $w $ms 'ic13' (8 + $Png2x.Length); $ms.Write($Png2x, 0, $Png2x.Length)
    $out = $ms.ToArray()
    $ms.Dispose()
    return ,$out
}

# ---------------------------------------------------------------------------------------------
#  Themes (Resources\Image\<Auteur>\<Theme>)
# ---------------------------------------------------------------------------------------------
function Get-Themes([string]$EfiOc) {
    $list = @()
    $root = Join-Path $EfiOc 'Resources\Image'
    if (-not (Test-Path -LiteralPath $root)) { return $list }
    foreach ($vendor in (Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name)) {
        foreach ($set in (Get-ChildItem -LiteralPath $vendor.FullName -Directory | Sort-Object Name)) {
            if (@(Get-ChildItem -LiteralPath $set.FullName -Filter '*.icns' -File).Count -gt 0) {
                $list += ($vendor.Name + '\' + $set.Name)
            }
        }
    }
    return $list
}

# Theme reellement utilise par OpenCanopy pour une valeur de PickerVariant.
function Resolve-Variant([string]$Variant, [string]$BgHex) {
    if (-not $Variant -or $Variant -eq 'Auto') {
        if ($BgHex -and $BgHex.ToUpper() -eq '#BFBFBF') { return 'Acidanthera\Chardonnay' }
        return 'Acidanthera\GoldenGate'
    }
    if ($Variant -eq 'Default') { return 'Acidanthera\GoldenGate' }
    return $Variant.Replace('/', '\')
}

function Get-ThemeDir([string]$EfiOc, [string]$ThemeRel) {
    return (Join-Path (Join-Path $EfiOc 'Resources\Image') $ThemeRel)
}

function Test-ThemeName([string]$Name) { return ($Name -match '^[A-Za-z0-9][A-Za-z0-9_\-]{0,40}$') }

function Get-FreeSpace([string]$Path) {
    try {
        $root = [IO.Path]::GetPathRoot($Path)
        return (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace
    } catch { return -1 }
}

function Assert-FreeSpace([string]$EfiOc, [int64]$Needed) {
    $free = Get-FreeSpace $EfiOc
    if ($free -ge 0 -and $free -lt ($Needed + 2MB)) { throw 'OCD_NO_SPACE' }
}

# Ecrit un fichier du theme apres sauvegarde.
function Set-ThemeFile([string]$EfiOc, [string]$ThemeRel, [string]$FileName, [byte[]]$Bytes, [string]$Reason) {
    $rel = Join-Path (Join-Path 'Resources\Image' $ThemeRel) $FileName
    $dst = Join-Path $EfiOc $rel
    Assert-FreeSpace $EfiOc $Bytes.Length
    $id = New-Backup $EfiOc $Reason @($rel)
    $parent = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    [IO.File]::WriteAllBytes($dst, $Bytes)
    return $id
}

function Remove-ThemeFile([string]$EfiOc, [string]$ThemeRel, [string]$FileName, [string]$Reason) {
    $rel = Join-Path (Join-Path 'Resources\Image' $ThemeRel) $FileName
    $dst = Join-Path $EfiOc $rel
    if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { return $null }
    $id = New-Backup $EfiOc $Reason @($rel)
    Remove-Item -LiteralPath $dst -Force
    return $id
}

# Copie un dossier d'icones vers Resources\Image\Custom\<Nom> (duplication ou import).
function Copy-ThemeFolder([string]$EfiOc, [string]$SourceDir, [string]$NewName, [string]$Reason) {
    if (-not (Test-ThemeName $NewName)) { throw 'OCD_BAD_NAME' }
    $files = @(Get-ChildItem -LiteralPath $SourceDir -File | Where-Object { $_.Extension -ieq '.icns' })
    if ($files.Count -eq 0) { throw 'OCD_NO_ICNS' }
    $themeRel = 'Custom\' + $NewName
    $dstDir = Get-ThemeDir $EfiOc $themeRel
    if (Test-Path -LiteralPath $dstDir) { throw 'OCD_EXISTS' }
    $size = 0; foreach ($f in $files) { $size += $f.Length }
    Assert-FreeSpace $EfiOc $size
    $rels = @(); foreach ($f in $files) { $rels += (Join-Path (Join-Path 'Resources\Image' $themeRel) $f.Name) }
    [void](New-Backup $EfiOc $Reason $rels)
    [void](New-Item -ItemType Directory -Path $dstDir -Force)
    foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dstDir $f.Name) -Force }
    return $themeRel
}

function Install-CanopyFile([string]$EfiOc, [string]$SourceFile) {
    $rel = 'Drivers\OpenCanopy.efi'
    $info = Get-Item -LiteralPath $SourceFile
    Assert-FreeSpace $EfiOc $info.Length
    [void](New-Backup $EfiOc 'install-opencanopy' @($rel))
    $dst = Join-Path $EfiOc $rel
    $parent = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    Copy-Item -LiteralPath $SourceFile -Destination $dst -Force
}

function Find-EfiFolders {
    $found = @()
    try {
        foreach ($d in [IO.DriveInfo]::GetDrives()) {
            if (-not $d.IsReady) { continue }
            $p = Join-Path $d.Name 'EFI\OC'
            if (Test-Path -LiteralPath (Join-Path $p 'config.plist')) { $found += $p }
        }
    } catch { }
    return $found
}

function Format-Size([int64]$Bytes) {
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Read-Settings {
    $s = @{ Lang = $null; LastEfi = $null }
    try {
        if (Test-Path -LiteralPath $script:SettingsFile) {
            $j = Get-Content -LiteralPath $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.Lang) { $s.Lang = [string]$j.Lang }
            if ($j.LastEfi) { $s.LastEfi = [string]$j.LastEfi }
        }
    } catch { }
    return $s
}

function Save-Settings($Settings) {
    try {
        if (-not (Test-Path -LiteralPath $script:AppDir)) { [void](New-Item -ItemType Directory -Path $script:AppDir -Force) }
        [IO.File]::WriteAllText($script:SettingsFile, ($Settings | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# ---------------------------------------------------------------------------------------------
#  Catalogue de themes en ligne
#  Sources limitees a deux depots GitHub, chacun fige sur un commit precis : le contenu
#  telecharge est donc exactement celui qui a ete repertorie, et ne peut pas changer.
# ---------------------------------------------------------------------------------------------
$script:CacheRoot    = Join-Path $script:AppDir 'Cache'
$script:AllowedHosts = @('raw.githubusercontent.com')
$script:MaxIcnsBytes = 48MB
# Icones d'interface qu'OpenCanopy attend : completees depuis GoldenGate si un theme ne les fournit pas.
$script:SupportIcons = @('Cursor', 'Selected', 'Selector', 'SetDefault', 'Left', 'Right', 'HardDrive',
                         'BtnFocus', 'Dot', 'Enter', 'Lock', 'Password', 'Restart', 'ShutDown')
$script:CatalogJson = @'
{"Sources":[{"Id":"acidanthera","Name":"Acidanthera (OcBinaryData)","Repo":"acidanthera/OcBinaryData","Commit":"32500d5e3313f11cad00351ba1c6f9a4aa6cb0f7","Url":"https://github.com/acidanthera/OcBinaryData"},{"Id":"blackosx","Name":"Blackosx (OpenCanopyIcons)","Repo":"blackosx/OpenCanopyIcons","Commit":"2ad4661cab26a001bdb844d9879190fb8d095ac2","Url":"https://github.com/blackosx/OpenCanopyIcons"}],"Themes":[{"Id":"acidanthera-GoldenGate","Source":"acidanthera","Group":"Acidanthera","Name":"GoldenGate","Note":"macOS 11","Vendor":"Acidanthera","Folder":"GoldenGate","Base":"Resources/Image/Acidanthera/GoldenGate","Set":"s1"},{"Id":"acidanthera-Syrah","Source":"acidanthera","Group":"Acidanthera","Name":"Syrah","Note":"OS X 10.10","Vendor":"Acidanthera","Folder":"Syrah","Base":"Resources/Image/Acidanthera/Syrah","Set":"s1"},{"Id":"acidanthera-Chardonnay","Source":"acidanthera","Group":"Acidanthera","Name":"Chardonnay","Note":"Mac OS X 10.4","Vendor":"Acidanthera","Folder":"Chardonnay","Base":"Resources/Image/Acidanthera/Chardonnay","Set":"s1"},{"Id":"blackosx-set3-aqua","Source":"blackosx","Group":"Set3","Name":"Aqua","Vendor":"Blackosx","Folder":"Set3-Aqua","Base":"Set3/Aqua","Files":{"Apple":"HardDrive/Apple/Apple_SSD_Aqua.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_Aqua.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_Aqua.icns","AppleRecv":"Recovery/AppleRecv_SSD_Aqua.icns","AppleTM":"Time Machine/AppleTM_Aqua.icns","ExtAppleTM":"Time Machine/ExtAppleTM_Aqua.icns","ExtApple":"External/ExtApple_Aqua.icns","ExtAppleRecv":"External/ExtAppleRecv_Aqua.icns","ExtHardDrive":"External/ExtHardDrive_Aqua.icns","Cursor":"Cursors/Cursor_Aqua.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_Aqua.icns","Shell":"Shell/Shell_Aqua.icns","Tool":"Tool/Tool_Aqua.icns","Selected":"Selected/Selected_Keyline_Aqua.icns","Selector":"Selector/Selector_No_Fill_Aqua.icns","SetDefault":"SetDefault/SetDefault_No_Fill_Aqua.icns","Left":"Scroll/Left_No_Fill_Aqua.icns","Right":"Scroll/Right_No_Fill_Aqua.icns","ShutDown":"ShutDown/ShutDown_Thin_Aqua.icns","Restart":"Restart/Restart_Thin_Aqua.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_Aqua.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_Aqua.icns","Enter":"Enter/Enter_No_Fill_Aqua.icns","Lock":"Lock/Lock_No_Fill_Aqua.icns","Password":"Password/Password_No_Fill_Aqua.icns"},"Backgrounds":{"1024x768":"Background/Aqua_01_(1024x768).icns","1280x800":"Background/Aqua_01_(1280x800).icns","1280x960":"Background/Aqua_01_(1280x960).icns","1366x768":"Background/Aqua_01_(1366x768).icns","1400x900":"Background/Aqua_01_(1400x900).icns","1440x1080":"Background/Aqua_01_(1440x1080).icns","1600x1200":"Background/Aqua_01_(1600x1200).icns","1600x900":"Background/Aqua_01_(1600x900).icns","1680x1050":"Background/Aqua_01_(1680x1050).icns","1920x1080":"Background/Aqua_01_(1920x1080).icns","1920x1200":"Background/Aqua_01_(1920x1200).icns"},"Preview":"preview_sheet_Aqua.jpg"},{"Id":"blackosx-set3-blue","Source":"blackosx","Group":"Set3","Name":"Blue","Vendor":"Blackosx","Folder":"Set3-Blue","Base":"Set3/Blue","Files":{"Apple":"HardDrive/Apple/Apple_SSD_Blue.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_Blue.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_Blue.icns","AppleRecv":"Recovery/AppleRecv_SSD_Blue.icns","AppleTM":"Time Machine/AppleTM_Blue.icns","ExtAppleTM":"Time Machine/ExtAppleTM_Blue.icns","ExtApple":"External/ExtApple_Blue.icns","ExtAppleRecv":"External/ExtAppleRecv_Blue.icns","ExtHardDrive":"External/ExtHardDrive_Blue.icns","Cursor":"Cursors/Cursor_Blue.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_Blue.icns","Shell":"Shell/Shell_Blue.icns","Tool":"Tool/Tool_Blue.icns","Selected":"Selected/Selected_Keyline_Blue.icns","Selector":"Selector/Selector_No_Fill_Blue.icns","SetDefault":"SetDefault/SetDefault_No_Fill_Blue.icns","Left":"Scroll/Left_No_Fill_Blue.icns","Right":"Scroll/Right_No_Fill_Blue.icns","ShutDown":"ShutDown/ShutDown_Thin_Blue.icns","Restart":"Restart/Restart_Thin_Blue.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_Blue.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_Blue.icns","Enter":"Enter/Enter_No_Fill_Blue.icns","Lock":"Lock/Lock_No_Fill_Blue.icns","Password":"Password/Password_No_Fill_Blue.icns"},"Backgrounds":{"1024x768":"Background/Blue_01_(1024x768).icns","1280x800":"Background/Blue_01_(1280x800).icns","1280x960":"Background/Blue_01_(1280x960).icns","1366x768":"Background/Blue_01_(1366x768).icns","1400x900":"Background/Blue_01_(1400x900).icns","1440x1080":"Background/Blue_01_(1440x1080).icns","1600x1200":"Background/Blue_01_(1600x1200).icns","1600x900":"Background/Blue_01_(1600x900).icns","1680x1050":"Background/Blue_01_(1680x1050).icns","1920x1080":"Background/Blue_01_(1920x1080).icns","1920x1200":"Background/Blue_01_(1920x1200).icns"},"Preview":"preview_sheet_Blue.jpg"},{"Id":"blackosx-set3-cardinal","Source":"blackosx","Group":"Set3","Name":"Cardinal","Vendor":"Blackosx","Folder":"Set3-Cardinal","Base":"Set3/Cardinal","Files":{"Apple":"HardDrive/Apple/Apple_SSD_Cardinal.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_Cardinal.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_Cardinal.icns","AppleRecv":"Recovery/AppleRecv_SSD_Cardinal.icns","AppleTM":"Time Machine/AppleTM_Cardinal.icns","ExtAppleTM":"Time Machine/ExtAppleTM_Cardinal.icns","ExtApple":"External/ExtApple_Cardinal.icns","ExtAppleRecv":"External/ExtAppleRecv_Cardinal.icns","ExtHardDrive":"External/ExtHardDrive_Cardinal.icns","Cursor":"Cursors/Cursor_Cardinal.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_Cardinal.icns","Shell":"Shell/Shell_Cardinal.icns","Tool":"Tool/Tool_Cardinal.icns","Selected":"Selected/Selected_Keyline_Cardinal.icns","Selector":"Selector/Selector_No_Fill_Cardinal.icns","SetDefault":"SetDefault/SetDefault_No_Fill_Cardinal.icns","Left":"Scroll/Left_No_Fill_Cardinal.icns","Right":"Scroll/Right_No_Fill_Cardinal.icns","ShutDown":"ShutDown/ShutDown_Thin_Cardinal.icns","Restart":"Restart/Restart_Thin_Cardinal.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_Cardinal.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_Cardinal.icns","Enter":"Enter/Enter_No_Fill_Cardinal.icns","Lock":"Lock/Lock_No_Fill_Cardinal.icns","Password":"Password/Password_No_Fill_Cardinal.icns"},"Backgrounds":{"1024x768":"Background/Cardinal_01_(1024x768).icns","1280x800":"Background/Cardinal_01_(1280x800).icns","1280x960":"Background/Cardinal_01_(1280x960).icns","1366x768":"Background/Cardinal_01_(1366x768).icns","1400x900":"Background/Cardinal_01_(1400x900).icns","1440x1080":"Background/Cardinal_01_(1440x1080).icns","1600x1200":"Background/Cardinal_01_(1600x1200).icns","1600x900":"Background/Cardinal_01_(1600x900).icns","1680x1050":"Background/Cardinal_01_(1680x1050).icns","1920x1080":"Background/Cardinal_01_(1920x1080).icns","1920x1200":"Background/Cardinal_01_(1920x1200).icns"},"Preview":"preview_sheet_Cardinal.jpg"},{"Id":"blackosx-set3-dark","Source":"blackosx","Group":"Set3","Name":"Dark","Vendor":"Blackosx","Folder":"Set3-Dark","Base":"Set3/Dark","Files":{"Apple":"HardDrive/Apple/Apple_SSD_Dark.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_Dark.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_Dark.icns","AppleRecv":"Recovery/AppleRecv_SSD_Dark.icns","AppleTM":"Time Machine/AppleTM_Dark.icns","ExtAppleTM":"Time Machine/ExtAppleTM_Dark.icns","ExtApple":"External/ExtApple_Dark.icns","ExtAppleRecv":"External/ExtAppleRecv_Dark.icns","ExtHardDrive":"External/ExtHardDrive_Dark.icns","Cursor":"Cursors/Cursor_Dark.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_Dark.icns","Shell":"Shell/Shell_Dark.icns","Tool":"Tool/Tool_Dark.icns","Selected":"Selected/Selected_Keyline_Dark.icns","Selector":"Selector/Selector_No_Fill_Dark.icns","SetDefault":"SetDefault/SetDefault_No_Fill_Dark.icns","Left":"Scroll/Left_No_Fill_Dark.icns","Right":"Scroll/Right_No_Fill_Dark.icns","ShutDown":"ShutDown/ShutDown_Thin_Dark.icns","Restart":"Restart/Restart_Thin_Dark.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_Dark.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_Dark.icns","Enter":"Enter/Enter_No_Fill_Dark.icns","Lock":"Lock/Lock_No_Fill_Dark.icns","Password":"Password/Password_No_Fill_Dark.icns"},"Backgrounds":{"1024x768":"Background/Dark_01_(1024x768).icns","1280x800":"Background/Dark_01_(1280x800).icns","1280x960":"Background/Dark_01_(1280x960).icns","1366x768":"Background/Dark_01_(1366x768).icns","1400x900":"Background/Dark_01_(1400x900).icns","1440x1080":"Background/Dark_01_(1440x1080).icns","1600x1200":"Background/Dark_01_(1600x1200).icns","1600x900":"Background/Dark_01_(1600x900).icns","1680x1050":"Background/Dark_01_(1680x1050).icns","1920x1080":"Background/Dark_01_(1920x1080).icns","1920x1200":"Background/Dark_01_(1920x1200).icns"},"Preview":"preview_sheet_Dark.jpg"},{"Id":"blackosx-set3-darkglow","Source":"blackosx","Group":"Set3","Name":"DarkGlow","Vendor":"Blackosx","Folder":"Set3-DarkGlow","Base":"Set3/DarkGlow","Files":{"Apple":"HardDrive/Apple/Apple_SSD_DarkGlow.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_DarkGlow.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_DarkGlow.icns","AppleRecv":"Recovery/AppleRecv_HDD_DarkGlow.icns","AppleTM":"Time Machine/AppleTM_DarkGlow.icns","ExtAppleTM":"Time Machine/ExtAppleTM_DarkGlow.icns","ExtApple":"External/ExtApple_DarkGlow.icns","ExtAppleRecv":"External/ExtAppleRecv_DarkGlow.icns","ExtHardDrive":"External/ExtHardDrive_DarkGlow.icns","Cursor":"Cursors/Cursor_DarkGlow.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_DarkGlow.icns","Shell":"Shell/Shell_DarkGlow_New.icns","Tool":"Tool/Tool_DarkGlow_New.icns","Selected":"Selected/Selected_Keyline_DarkGlow.icns","Selector":"Selector/Selector_No_Fill_DarkGlow.icns","SetDefault":"SetDefault/SetDefault_No_Fill_DarkGlow.icns","Left":"Scroll/Left_No_Fill_DarkGlow.icns","Right":"Scroll/Right_No_Fill_DarkGlow.icns","ShutDown":"ShutDown/ShutDown_Thin_DarkGlow.icns","Restart":"Restart/Restart_Thin_DarkGlow.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_DarkGlow.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_DarkGlow.icns","Enter":"Enter/Enter_No_Fill_DarkGlow.icns","Lock":"Lock/Lock_No_Fill_DarkGlow.icns","Password":"Password/Password_No_Fill_DarkGlow.icns"},"Backgrounds":{"1024x768":"Background/DarkGlow_01_(1024x768).icns","1280x800":"Background/DarkGlow_01_(1280x800).icns","1280x960":"Background/DarkGlow_01_(1280x960).icns","1366x768":"Background/DarkGlow_01_(1366x768).icns","1440x1080":"Background/DarkGlow_01_(1440x1080).icns","1440x900":"Background/DarkGlow_01_(1440x900).icns","1600x1200":"Background/DarkGlow_01_(1600x1200).icns","1600x900":"Background/DarkGlow_01_(1600x900).icns","1680x1050":"Background/DarkGlow_01_(1680x1050).icns","1920x1080":"Background/DarkGlow_01_(1920x1080).icns","1920x1200":"Background/DarkGlow_01_(1920x1200).icns"},"Preview":"preview_sheet_DarkGlow.jpg"},{"Id":"blackosx-set3-green","Source":"blackosx","Group":"Set3","Name":"Green","Vendor":"Blackosx","Folder":"Set3-Green","Base":"Set3/Green","Files":{"Apple":"HardDrive/Apple/Apple_SSD_Green.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_Green.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_Green.icns","AppleRecv":"Recovery/AppleRecv_SSD_Green.icns","AppleTM":"Time Machine/AppleTM_Green.icns","ExtAppleTM":"Time Machine/ExtAppleTM_Green.icns","ExtApple":"External/ExtApple_Green.icns","ExtAppleRecv":"External/ExtAppleRecv_Green.icns","ExtHardDrive":"External/ExtHardDrive_Green.icns","Cursor":"Cursors/Cursor_Green.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_Green.icns","Shell":"Shell/Shell_Green.icns","Tool":"Tool/Tool_Green.icns","Selected":"Selected/Selected_Keyline_Green.icns","Selector":"Selector/Selector_No_Fill_Green.icns","SetDefault":"SetDefault/SetDefault_No_Fill_Green.icns","Left":"Scroll/Left_No_Fill_Green.icns","Right":"Scroll/Right_No_Fill_Green.icns","ShutDown":"ShutDown/ShutDown_Thin_Green.icns","Restart":"Restart/Restart_Thin_Green.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_Green.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_Green.icns","Enter":"Enter/Enter_No_Fill_Green.icns","Lock":"Lock/Lock_No_Fill_Green.icns","Password":"Password/Password_No_Fill_Green.icns"},"Backgrounds":{"1024x768":"Background/Green_01_(1024x768).icns","1280x800":"Background/Green_01_(1280x800).icns","1280x960":"Background/Green_01_(1280x960).icns","1366x768":"Background/Green_01_(1366x768).icns","1400x900":"Background/Green_01_(1400x900).icns","1440x1080":"Background/Green_01_(1440x1080).icns","1600x1200":"Background/Green_01_(1600x1200).icns","1600x900":"Background/Green_01_(1600x900).icns","1680x1050":"Background/Green_01_(1680x1050).icns","1920x1080":"Background/Green_01_(1920x1080).icns","1920x1200":"Background/Green_01_(1920x1200).icns"},"Preview":"preview_sheet_Green.jpg"},{"Id":"blackosx-set3-light","Source":"blackosx","Group":"Set3","Name":"Light","Vendor":"Blackosx","Folder":"Set3-Light","Base":"Set3/Light","Files":{"Apple":"HardDrive/Apple/Apple_SSD_Light.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_Light.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_Light.icns","AppleRecv":"Recovery/AppleRecv_SSD_Light.icns","AppleTM":"Time Machine/AppleTM_Light.icns","ExtAppleTM":"Time Machine/ExtAppleTM_Light.icns","ExtApple":"External/ExtApple_Light.icns","ExtAppleRecv":"External/ExtAppleRecv_Light.icns","ExtHardDrive":"External/ExtHardDrive_Light.icns","Cursor":"Cursors/Cursor_Light.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_Light.icns","Shell":"Shell/Shell_Light.icns","Tool":"Tool/Tool_Light.icns","Selected":"Selected/Selected_Keyline_Light.icns","Selector":"Selector/Selector_No_Fill_Light.icns","SetDefault":"SetDefault/SetDefault_No_Fill_Light.icns","Left":"Scroll/Left_No_Fill_Light.icns","Right":"Scroll/Right_No_Fill_Light.icns","ShutDown":"ShutDown/ShutDown_Thin_Light.icns","Restart":"Restart/Restart_Thin_Light.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_Light.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_Light.icns","Enter":"Enter/Enter_No_Fill_Light.icns","Lock":"Lock/Lock_No_Fill_Light.icns","Password":"Password/Password_No_Fill_Light.icns"},"Backgrounds":{"1024x768":"Background/Light_01_(1024x768).icns","1280x800":"Background/Light_01_(1280x800).icns","1280x960":"Background/Light_01_(1280x960).icns","1366x768":"Background/Light_01_(1366x768).icns","1400x900":"Background/Light_01_(1400x900).icns","1440x1080":"Background/Light_01_(1440x1080).icns","1600x1200":"Background/Light_01_(1600x1200).icns","1600x900":"Background/Light_01_(1600x900).icns","1680x1050":"Background/Light_01_(1680x1050).icns","1920x1080":"Background/Light_01_(1920x1080).icns","1920x1200":"Background/Light_01_(1920x1200).icns"},"Preview":"preview_sheet_Light.jpg"},{"Id":"blackosx-set3-lightblue","Source":"blackosx","Group":"Set3","Name":"LightBlue","Vendor":"Blackosx","Folder":"Set3-LightBlue","Base":"Set3/LightBlue","Files":{"Apple":"HardDrive/Apple/Apple_SSD_LightBlue.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_LightBlue.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_LightBlue.icns","AppleRecv":"Recovery/AppleRecv_SSD_LightBlue.icns","AppleTM":"Time Machine/AppleTM_LightBlue.icns","ExtAppleTM":"Time Machine/ExtAppleTM_LightBlue.icns","ExtApple":"External/ExtApple_LightBlue.icns","ExtAppleRecv":"External/ExtAppleRecv_LightBlue.icns","ExtHardDrive":"External/ExtHardDrive_LightBlue.icns","Cursor":"Cursors/Cursor_LightBlue.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_LightBlue.icns","Shell":"Shell/Shell_LightBlue.icns","Tool":"Tool/Tool_LightBlue.icns","Selected":"Selected/Selected_Keyline_LightBlue.icns","Selector":"Selector/Selector_No_Fill_LightBlue.icns","SetDefault":"SetDefault/SetDefault_No_Fill_LightBlue.icns","Left":"Scroll/Left_No_Fill_LightBlue.icns","Right":"Scroll/Right_No_Fill_LightBlue.icns","ShutDown":"ShutDown/ShutDown_Thin_LightBlue.icns","Restart":"Restart/Restart_Thin_LightBlue.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_LightBlue.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_LightBlue.icns","Enter":"Enter/Enter_No_Fill_LightBlue.icns","Lock":"Lock/Lock_No_Fill_LightBlue.icns","Password":"Password/Password_No_Fill_LightBlue.icns"},"Backgrounds":{"1024x768":"Background/LightBlue_01_(1024x768).icns","1280x800":"Background/LightBlue_01_(1280x800).icns","1280x960":"Background/LightBlue_01_(1280x960).icns","1366x768":"Background/LightBlue_01_(1366x768).icns","1400x900":"Background/LightBlue_01_(1400x900).icns","1440x1080":"Background/LightBlue_01_(1440x1080).icns","1600x1200":"Background/LightBlue_01_(1600x1200).icns","1600x900":"Background/LightBlue_01_(1600x900).icns","1680x1050":"Background/LightBlue_01_(1680x1050).icns","1920x1080":"Background/LightBlue_01_(1920x1080).icns","1920x1200":"Background/LightBlue_01_(1920x1200).icns"},"Preview":"preview_sheet_LightBlue.jpg"},{"Id":"blackosx-set3-lightglow","Source":"blackosx","Group":"Set3","Name":"LightGlow","Vendor":"Blackosx","Folder":"Set3-LightGlow","Base":"Set3/LightGlow","Files":{"Apple":"HardDrive/Apple/Apple_SSD_LightGlow.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_LightGlow.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_LightGlow.icns","AppleRecv":"Recovery/AppleRecv_HDD_LightGlow.icns","AppleTM":"Time Machine/AppleTM_LightGlow.icns","ExtAppleTM":"Time Machine/ExtAppleTM_LightGlow.icns","ExtApple":"External/ExtApple_LightGlow.icns","ExtAppleRecv":"External/ExtAppleRecv_LightGlow.icns","ExtHardDrive":"External/ExtHardDrive_LightGlow.icns","Cursor":"Cursors/Cursor_LightGlow.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_LightGlow.icns","Shell":"Shell/Shell_LightGlow_New.icns","Tool":"Tool/Tool_LightGlow_New.icns","Selected":"Selected/Selected_Keyline_LightGlow.icns","Selector":"Selector/Selector_No_Fill_LightGlow.icns","SetDefault":"SetDefault/SetDefault_No_Fill_LightGlow.icns","Left":"Scroll/Left_No_Fill_LightGlow.icns","Right":"Scroll/Right_No_Fill_LightGlow.icns","ShutDown":"ShutDown/ShutDown_Thin_LightGlow.icns","Restart":"Restart/Restart_Thin_LightGlow.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_LightGlow.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_LightGlow.icns","Enter":"Enter/Enter_No_Fill_LightGlow.icns","Lock":"Lock/Lock_No_Fill_LightGlow.icns","Password":"Password/Password_No_Fill_LightGlow.icns"},"Backgrounds":{"1024x768":"Background/LightGlow_01_(1024x768).icns","1280x800":"Background/LightGlow_01_(1280x800).icns","1280x960":"Background/LightGlow_01_(1280x960).icns","1366x768":"Background/LightGlow_01_(1366x768).icns","1440x1080":"Background/LightGlow_01_(1440x1080).icns","1440x900":"Background/LightGlow_01_(1440x900).icns","1600x1200":"Background/LightGlow_01_(1600x1200).icns","1600x900":"Background/LightGlow_01_(1600x900).icns","1680x1050":"Background/LightGlow_01_(1680x1050).icns","1920x1080":"Background/LightGlow_01_(1920x1080).icns","1920x1200":"Background/LightGlow_01_(1920x1200).icns"},"Preview":"preview_sheet_LightGlow.jpg"},{"Id":"blackosx-set3-lime","Source":"blackosx","Group":"Set3","Name":"Lime","Vendor":"Blackosx","Folder":"Set3-Lime","Base":"Set3/Lime","Files":{"Apple":"HardDrive/Apple/Apple_SSD_Lime.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_Lime.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_Lime.icns","AppleRecv":"Recovery/AppleRecv_SSD_Lime.icns","AppleTM":"Time Machine/AppleTM_Lime.icns","ExtAppleTM":"Time Machine/ExtAppleTM_Lime.icns","ExtApple":"External/ExtApple_Lime.icns","ExtAppleRecv":"External/ExtAppleRecv_Lime.icns","ExtHardDrive":"External/ExtHardDrive_Lime.icns","Cursor":"Cursors/Cursor_Lime.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_Lime.icns","Shell":"Shell/Shell_Lime.icns","Tool":"Tool/Tool_Lime.icns","Selected":"Selected/Selected_Keyline_Lime.icns","Selector":"Selector/Selector_No_Fill_Lime.icns","SetDefault":"SetDefault/SetDefault_No_Fill_Lime.icns","Left":"Scroll/Left_No_Fill_Lime.icns","Right":"Scroll/Right_No_Fill_Lime.icns","ShutDown":"ShutDown/ShutDown_Thin_Lime.icns","Restart":"Restart/Restart_Thin_Lime.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_Lime.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_Lime.icns","Enter":"Enter/Enter_No_Fill_Lime.icns","Lock":"Lock/Lock_No_Fill_Lime.icns","Password":"Password/Password_No_Fill_Lime.icns"},"Backgrounds":{"1024x768":"Background/Lime_01_(1024x768).icns","1280x800":"Background/Lime_01_(1280x800).icns","1280x960":"Background/Lime_01_(1280x960).icns","1366x768":"Background/Lime_01_(1366x768).icns","1400x900":"Background/Lime_01_(1400x900).icns","1440x1080":"Background/Lime_01_(1440x1080).icns","1600x1200":"Background/Lime_01_(1600x1200).icns","1600x900":"Background/Lime_01_(1600x900).icns","1680x1050":"Background/Lime_01_(1680x1050).icns","1920x1080":"Background/Lime_01_(1920x1080).icns","1920x1200":"Background/Lime_01_(1920x1200).icns"},"Preview":"preview_sheet_Lime.jpg"},{"Id":"blackosx-set3-orange","Source":"blackosx","Group":"Set3","Name":"Orange","Vendor":"Blackosx","Folder":"Set3-Orange","Base":"Set3/Orange","Files":{"Apple":"HardDrive/Apple/Apple_SSD_Orange.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_Orange.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_Orange.icns","AppleRecv":"Recovery/AppleRecv_SSD_Orange.icns","AppleTM":"Time Machine/AppleTM_Orange.icns","ExtAppleTM":"Time Machine/ExtAppleTM_Orange.icns","ExtApple":"External/ExtApple_Orange.icns","ExtAppleRecv":"External/ExtAppleRecv_Orange.icns","ExtHardDrive":"External/ExtHardDrive_Orange.icns","Cursor":"Cursors/Cursor_Orange.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_Orange.icns","Shell":"Shell/Shell_Orange.icns","Tool":"Tool/Tool_Orange.icns","Selected":"Selected/Selected_Keyline_Orange.icns","Selector":"Selector/Selector_No_Fill_Orange.icns","SetDefault":"SetDefault/SetDefault_No_Fill_Orange.icns","Left":"Scroll/Left_No_Fill_Orange.icns","Right":"Scroll/Right_No_Fill_Orange.icns","ShutDown":"ShutDown/ShutDown_Thin_Orange.icns","Restart":"Restart/Restart_Thin_Orange.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_Orange.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_Orange.icns","Enter":"Enter/Enter_No_Fill_Orange.icns","Lock":"Lock/Lock_No_Fill_Orange.icns","Password":"Password/Password_No_Fill_Orange.icns"},"Backgrounds":{"1024x768":"Background/Orange_01_(1024x768).icns","1280x800":"Background/Orange_01_(1280x800).icns","1280x960":"Background/Orange_01_(1280x960).icns","1366x768":"Background/Orange_01_(1366x768).icns","1400x900":"Background/Orange_01_(1400x900).icns","1440x1080":"Background/Orange_01_(1440x1080).icns","1600x1200":"Background/Orange_01_(1600x1200).icns","1600x900":"Background/Orange_01_(1600x900).icns","1680x1050":"Background/Orange_01_(1680x1050).icns","1920x1080":"Background/Orange_01_(1920x1080).icns","1920x1200":"Background/Orange_01_(1920x1200).icns"},"Preview":"preview_sheet_Orange.jpg"},{"Id":"blackosx-set3-pink","Source":"blackosx","Group":"Set3","Name":"Pink","Vendor":"Blackosx","Folder":"Set3-Pink","Base":"Set3/Pink","Files":{"Apple":"HardDrive/Apple/Apple_SSD_Pink.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_Pink.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_Pink.icns","AppleRecv":"Recovery/AppleRecv_SSD_Pink.icns","AppleTM":"Time Machine/AppleTM_Pink.icns","ExtAppleTM":"Time Machine/ExtAppleTM_Pink.icns","ExtApple":"External/ExtApple_Pink.icns","ExtAppleRecv":"External/ExtAppleRecv_Pink.icns","ExtHardDrive":"External/ExtHardDrive_Pink.icns","Cursor":"Cursors/Cursor_Pink.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_Pink.icns","Shell":"Shell/Shell_Pink.icns","Tool":"Tool/Tool_Pink.icns","Selected":"Selected/Selected_Keyline_Pink.icns","Selector":"Selector/Selector_No_Fill_Pink.icns","SetDefault":"SetDefault/SetDefault_No_Fill_Pink.icns","Left":"Scroll/Left_No_Fill_Pink.icns","Right":"Scroll/Right_No_Fill_Pink.icns","ShutDown":"ShutDown/ShutDown_Thin_Pink.icns","Restart":"Restart/Restart_Thin_Pink.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_Pink.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_Pink.icns","Enter":"Enter/Enter_No_Fill_Pink.icns","Lock":"Lock/Lock_No_Fill_Pink.icns","Password":"Password/Password_No_Fill_Pink.icns"},"Backgrounds":{"1024x768":"Background/Pink_01_(1024x768).icns","1280x800":"Background/Pink_01_(1280x800).icns","1280x960":"Background/Pink_01_(1280x960).icns","1366x768":"Background/Pink_01_(1366x768).icns","1400x900":"Background/Pink_01_(1400x900).icns","1440x1080":"Background/Pink_01_(1440x1080).icns","1600x1200":"Background/Pink_01_(1600x1200).icns","1600x900":"Background/Pink_01_(1600x900).icns","1680x1050":"Background/Pink_01_(1680x1050).icns","1920x1080":"Background/Pink_01_(1920x1080).icns","1920x1200":"Background/Pink_01_(1920x1200).icns"},"Preview":"preview_sheet_Pink.jpg"},{"Id":"blackosx-set3-purple","Source":"blackosx","Group":"Set3","Name":"Purple","Vendor":"Blackosx","Folder":"Set3-Purple","Base":"Set3/Purple","Files":{"Apple":"HardDrive/Apple/Apple_SSD_Purple.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_Purple.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_Purple.icns","AppleRecv":"Recovery/AppleRecv_SSD_Purple.icns","AppleTM":"Time Machine/AppleTM_Purple.icns","ExtAppleTM":"Time Machine/ExtAppleTM_Purple.icns","ExtApple":"External/ExtApple_Purple.icns","ExtAppleRecv":"External/ExtAppleRecv_Purple.icns","ExtHardDrive":"External/ExtHardDrive_Purple.icns","Cursor":"Cursors/Cursor_Purple.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_Purple.icns","Shell":"Shell/Shell_Purple.icns","Tool":"Tool/Tool_Purple.icns","Selected":"Selected/Selected_Keyline_Purple.icns","Selector":"Selector/Selector_No_Fill_Purple.icns","SetDefault":"SetDefault/SetDefault_No_Fill_Purple.icns","Left":"Scroll/Left_No_Fill_Purple.icns","Right":"Scroll/Right_No_Fill_Purple.icns","ShutDown":"ShutDown/ShutDown_Thin_Purple.icns","Restart":"Restart/Restart_Thin_Purple.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_Purple.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_Purple.icns","Enter":"Enter/Enter_No_Fill_Purple.icns","Lock":"Lock/Lock_No_Fill_Purple.icns","Password":"Password/Password_No_Fill_Purple.icns"},"Backgrounds":{"1024x768":"Background/Purple_01_(1024x768).icns","1280x800":"Background/Purple_01_(1280x800).icns","1280x960":"Background/Purple_01_(1280x960).icns","1366x768":"Background/Purple_01_(1366x768).icns","1400x900":"Background/Purple_01_(1400x900).icns","1440x1080":"Background/Purple_01_(1440x1080).icns","1600x1200":"Background/Purple_01_(1600x1200).icns","1600x900":"Background/Purple_01_(1600x900).icns","1680x1050":"Background/Purple_01_(1680x1050).icns","1920x1080":"Background/Purple_01_(1920x1080).icns","1920x1200":"Background/Purple_01_(1920x1200).icns"},"Preview":"preview_sheet_Purple.jpg"},{"Id":"blackosx-set3-red","Source":"blackosx","Group":"Set3","Name":"Red","Vendor":"Blackosx","Folder":"Set3-Red","Base":"Set3/Red","Files":{"Apple":"HardDrive/Apple/Apple_SSD_Red.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_Red.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_Red.icns","AppleRecv":"Recovery/AppleRecv_SSD_Red.icns","AppleTM":"Time Machine/AppleTM_Red.icns","ExtAppleTM":"Time Machine/ExtAppleTM_Red.icns","ExtApple":"External/ExtApple_Red.icns","ExtAppleRecv":"External/ExtAppleRecv_Red.icns","ExtHardDrive":"External/ExtHardDrive_Red.icns","Cursor":"Cursors/Cursor_Red.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_Red.icns","Shell":"Shell/Shell_Red.icns","Tool":"Tool/Tool_Red.icns","Selected":"Selected/Selected_Keyline_Red.icns","Selector":"Selector/Selector_No_Fill_Red.icns","SetDefault":"SetDefault/SetDefault_No_Fill_Red.icns","Left":"Scroll/Left_No_Fill_Red.icns","Right":"Scroll/Right_No_Fill_Red.icns","ShutDown":"ShutDown/ShutDown_Thin_Red.icns","Restart":"Restart/Restart_Thin_Red.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_Red.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_Red.icns","Enter":"Enter/Enter_No_Fill_Red.icns","Lock":"Lock/Lock_No_Fill_Red.icns","Password":"Password/Password_No_Fill_Red.icns"},"Backgrounds":{"1024x768":"Background/Red_01_(1024x768).icns","1280x800":"Background/Red_01_(1280x800).icns","1280x960":"Background/Red_01_(1280x960).icns","1366x768":"Background/Red_01_(1366x768).icns","1400x900":"Background/Red_01_(1400x900).icns","1440x1080":"Background/Red_01_(1440x1080).icns","1600x1200":"Background/Red_01_(1600x1200).icns","1600x900":"Background/Red_01_(1600x900).icns","1680x1050":"Background/Red_01_(1680x1050).icns","1920x1080":"Background/Red_01_(1920x1080).icns","1920x1200":"Background/Red_01_(1920x1200).icns"},"Preview":"preview_sheet_Red.jpg"},{"Id":"blackosx-set3-silverblue","Source":"blackosx","Group":"Set3","Name":"SilverBlue","Vendor":"Blackosx","Folder":"Set3-SilverBlue","Base":"Set3/SilverBlue","Files":{"Apple":"HardDrive/Apple/Apple_SSD_SilverBlue.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_SilverBlue.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_SilverBlue.icns","AppleRecv":"Recovery/AppleRecv_SSD_SilverBlue.icns","AppleTM":"Time Machine/AppleTM_SilverBlue.icns","ExtAppleTM":"Time Machine/ExtAppleTM_SilverBlue.icns","ExtApple":"External/ExtApple_SilverBlue.icns","ExtAppleRecv":"External/ExtAppleRecv_SilverBlue.icns","ExtHardDrive":"External/ExtHardDrive_SilverBlue.icns","Cursor":"Cursors/Cursor_SilverBlue.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_SilverBlue.icns","Shell":"Shell/Shell_SilverBlue.icns","Tool":"Tool/Tool_SilverBlue.icns","Selected":"Selected/Selected_Keyline_SilverBlue.icns","Selector":"Selector/Selector_No_Fill_SilverBlue.icns","SetDefault":"SetDefault/SetDefault_No_Fill_SilverBlue.icns","Left":"Scroll/Left_No_Fill_SilverBlue.icns","Right":"Scroll/Right_No_Fill_SilverBlue.icns","ShutDown":"ShutDown/ShutDown_Thin_SilverBlue.icns","Restart":"Restart/Restart_Thin_SilverBlue.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_SilverBlue.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_SilverBlue.icns","Enter":"Enter/Enter_No_Fill_SilverBlue.icns","Lock":"Lock/Lock_No_Fill_SilverBlue.icns","Password":"Password/Password_No_Fill_SilverBlue.icns"},"Backgrounds":{"1024x768":"Background/SilverBlue_01_(1024x768).icns","1280x800":"Background/SilverBlue_01_(1280x800).icns","1280x960":"Background/SilverBlue_01_(1280x960).icns","1366x768":"Background/SilverBlue_01_(1366x768).icns","1400x900":"Background/SilverBlue_01_(1400x900).icns","1440x1080":"Background/SilverBlue_01_(1440x1080).icns","1600x1200":"Background/SilverBlue_01_(1600x1200).icns","1600x900":"Background/SilverBlue_01_(1600x900).icns","1680x1050":"Background/SilverBlue_01_(1680x1050).icns","1920x1080":"Background/SilverBlue_01_(1920x1080).icns","1920x1200":"Background/SilverBlue_01_(1920x1200).icns"},"Preview":"preview_sheet_SilverBlue.jpg"},{"Id":"blackosx-set3-silvergold","Source":"blackosx","Group":"Set3","Name":"SilverGold","Vendor":"Blackosx","Folder":"Set3-SilverGold","Base":"Set3/SilverGold","Files":{"Apple":"HardDrive/Apple/Apple_SSD_SilverGold.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_SilverGold.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_SilverGold.icns","AppleRecv":"Recovery/AppleRecv_HDD_SilverGold.icns","AppleTM":"Time Machine/AppleTM_SilverGold.icns","ExtAppleTM":"Time Machine/ExtAppleTM_SilverGold.icns","ExtApple":"External/ExtApple_SilverGold.icns","ExtAppleRecv":"External/ExtAppleRecv_SilverGold.icns","ExtHardDrive":"External/ExtHardDrive_SilverGold.icns","Cursor":"Cursors/Cursor_SilverGold.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_SilverGold.icns","Shell":"Shell/Shell_SilverGold.icns","Tool":"Tool/Tool_SilverGold.icns","Selected":"Selected/Selected_Keyline_SilverGold.icns","Selector":"Selector/Selector_No_Fill_SilverGold.icns","SetDefault":"SetDefault/SetDefault_No_Fill_SilverGold.icns","Left":"Scroll/Left_No_Fill_SilverGold.icns","Right":"Scroll/Right_No_Fill_SilverGold.icns","ShutDown":"ShutDown/ShutDown_Thin_SilverGold.icns","Restart":"Restart/Restart_Thin_SilverGold.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_SilverGold.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_SilverGold.icns","Enter":"Enter/Enter_No_Fill_SilverGold.icns","Lock":"Lock/Lock_No_Fill_SilverGold.icns","Password":"Password/Password_No_Fill_SilverGold.icns"},"Backgrounds":{"1024x768":"Background/SilverGold_01_(1024x768).icns","1280x800":"Background/SilverGold_01_(1280x800).icns","1280x960":"Background/SilverGold_01_(1280x960).icns","1366x768":"Background/SilverGold_01_(1366x768).icns","1400x900":"Background/SilverGold_01_(1400x900).icns","1440x1080":"Background/SilverGold_01_(1440x1080).icns","1600x1200":"Background/SilverGold_01_(1600x1200).icns","1600x900":"Background/SilverGold_01_(1600x900).icns","1680x1050":"Background/SilverGold_01_(1680x1050).icns","1920x1080":"Background/SilverGold_01_(1920x1080).icns","1920x1200":"Background/SilverGold_01_(1920x1200).icns"},"Preview":"preview_sheet_SilverGold.jpg"},{"Id":"blackosx-set3-violet","Source":"blackosx","Group":"Set3","Name":"Violet","Vendor":"Blackosx","Folder":"Set3-Violet","Base":"Set3/Violet","Files":{"Apple":"HardDrive/Apple/Apple_SSD_Violet.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_Violet.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_Violet.icns","AppleRecv":"Recovery/AppleRecv_SSD_Violet.icns","AppleTM":"Time Machine/AppleTM_Violet.icns","ExtAppleTM":"Time Machine/ExtAppleTM_Violet.icns","ExtApple":"External/ExtApple_Violet.icns","ExtAppleRecv":"External/ExtAppleRecv_Violet.icns","ExtHardDrive":"External/ExtHardDrive_Violet.icns","Cursor":"Cursors/Cursor_Violet.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_Violet.icns","Shell":"Shell/Shell_Violet.icns","Tool":"Tool/Tool_Violet.icns","Selected":"Selected/Selected_Keyline_Violet.icns","Selector":"Selector/Selector_No_Fill_Violet.icns","SetDefault":"SetDefault/SetDefault_No_Fill_Violet.icns","Left":"Scroll/Left_No_Fill_Violet.icns","Right":"Scroll/Right_No_Fill_Violet.icns","ShutDown":"ShutDown/ShutDown_Thin_Violet.icns","Restart":"Restart/Restart_Thin_Violet.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_Violet.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_Violet.icns","Enter":"Enter/Enter_No_Fill_Violet.icns","Lock":"Lock/Lock_No_Fill_Violet.icns","Password":"Password/Password_No_Fill_Violet.icns"},"Backgrounds":{"1024x768":"Background/Violet_01_(1024x768).icns","1280x800":"Background/Violet_01_(1280x800).icns","1280x960":"Background/Violet_01_(1280x960).icns","1366x768":"Background/Violet_01_(1366x768).icns","1400x900":"Background/Violet_01_(1400x900).icns","1440x1080":"Background/Violet_01_(1440x1080).icns","1600x1200":"Background/Violet_01_(1600x1200).icns","1600x900":"Background/Violet_01_(1600x900).icns","1680x1050":"Background/Violet_01_(1680x1050).icns","1920x1080":"Background/Violet_01_(1920x1080).icns","1920x1200":"Background/Violet_01_(1920x1200).icns"},"Preview":"preview_sheet_Violet.jpg"},{"Id":"blackosx-set3-yellow","Source":"blackosx","Group":"Set3","Name":"Yellow","Vendor":"Blackosx","Folder":"Set3-Yellow","Base":"Set3/Yellow","Files":{"Apple":"HardDrive/Apple/Apple_SSD_Yellow.icns","HardDrive":"HardDrive/Generic/HardDrive_SSD_Yellow.icns","Windows":"HardDrive/Microsoft/HardDrive_SSD_Windows11_Yellow.icns","AppleRecv":"Recovery/AppleRecv_SSD_Yellow.icns","AppleTM":"Time Machine/AppleTM_Yellow.icns","ExtAppleTM":"Time Machine/ExtAppleTM_Yellow.icns","ExtApple":"External/ExtApple_Yellow.icns","ExtAppleRecv":"External/ExtAppleRecv_Yellow.icns","ExtHardDrive":"External/ExtHardDrive_Yellow.icns","Cursor":"Cursors/Cursor_Yellow.icns","ResetNVRAM":"ResetNVRAM/ResetNVRAM_Yellow.icns","Shell":"Shell/Shell_Yellow.icns","Tool":"Tool/Tool_Yellow.icns","Selected":"Selected/Selected_Keyline_Yellow.icns","Selector":"Selector/Selector_No_Fill_Yellow.icns","SetDefault":"SetDefault/SetDefault_No_Fill_Yellow.icns","Left":"Scroll/Left_No_Fill_Yellow.icns","Right":"Scroll/Right_No_Fill_Yellow.icns","ShutDown":"ShutDown/ShutDown_Thin_Yellow.icns","Restart":"Restart/Restart_Thin_Yellow.icns","BtnFocus":"BtnFocus/BtnFocus_No_Fill_Yellow.icns","Dot":"Dot/Dot_No_Fill_100_Keyline_Yellow.icns","Enter":"Enter/Enter_No_Fill_Yellow.icns","Lock":"Lock/Lock_No_Fill_Yellow.icns","Password":"Password/Password_No_Fill_Yellow.icns"},"Backgrounds":{"1024x768":"Background/Yellow_01_(1024x768).icns","1280x800":"Background/Yellow_01_(1280x800).icns","1280x960":"Background/Yellow_01_(1280x960).icns","1366x768":"Background/Yellow_01_(1366x768).icns","1400x900":"Background/Yellow_01_(1400x900).icns","1440x1080":"Background/Yellow_01_(1440x1080).icns","1600x1200":"Background/Yellow_01_(1600x1200).icns","1600x900":"Background/Yellow_01_(1600x900).icns","1680x1050":"Background/Yellow_01_(1680x1050).icns","1920x1080":"Background/Yellow_01_(1920x1080).icns","1920x1200":"Background/Yellow_01_(1920x1200).icns"},"Preview":"preview_sheet_Yellow.jpg"},{"Id":"blackosx-set3le-blueglow","Source":"blackosx","Group":"Set3LE","Name":"BlueGlow","Vendor":"Blackosx","Folder":"Set3LE-BlueGlow","Base":"Set3LE/BlueGlow","Preview":"preview_sheet_BlueGlow.jpg","Set":"s2"},{"Id":"blackosx-set3le-greenglow","Source":"blackosx","Group":"Set3LE","Name":"GreenGlow","Vendor":"Blackosx","Folder":"Set3LE-GreenGlow","Base":"Set3LE/GreenGlow","Preview":"preview_sheet_GreenGlow.jpg","Set":"s2"},{"Id":"blackosx-set3le-lightblueglow","Source":"blackosx","Group":"Set3LE","Name":"LightBlueGlow","Vendor":"Blackosx","Folder":"Set3LE-LightBlueGlow","Base":"Set3LE/LightBlueGlow","Preview":"preview_sheet_LightBlueGlow.jpg","Set":"s2"},{"Id":"blackosx-set3le-orangeglow","Source":"blackosx","Group":"Set3LE","Name":"OrangeGlow","Vendor":"Blackosx","Folder":"Set3LE-OrangeGlow","Base":"Set3LE/OrangeGlow","Preview":"preview_sheet_OrangeGlow.jpg","Set":"s2"},{"Id":"blackosx-set3le-redglow","Source":"blackosx","Group":"Set3LE","Name":"RedGlow","Vendor":"Blackosx","Folder":"Set3LE-RedGlow","Base":"Set3LE/RedGlow","Preview":"preview_sheet_RedGlow.jpg","Set":"s2"},{"Id":"blackosx-set4b-blue","Source":"blackosx","Group":"Set4b","Name":"Blue","Vendor":"Blackosx","Folder":"Set4b-Blue","Base":"Set4b/Blue","Backgrounds":{"any":"../Background/Background.icns"},"Set":"s3"},{"Id":"blackosx-set4b-darkgrey","Source":"blackosx","Group":"Set4b","Name":"DarkGrey","Vendor":"Blackosx","Folder":"Set4b-DarkGrey","Base":"Set4b/DarkGrey","Backgrounds":{"any":"../Background/Background.icns"},"Set":"s3"},{"Id":"blackosx-set4b-green","Source":"blackosx","Group":"Set4b","Name":"Green","Vendor":"Blackosx","Folder":"Set4b-Green","Base":"Set4b/Green","Backgrounds":{"any":"../Background/Background.icns"},"Set":"s3"},{"Id":"blackosx-set4b-light","Source":"blackosx","Group":"Set4b","Name":"Light","Vendor":"Blackosx","Folder":"Set4b-Light","Base":"Set4b/Light","Backgrounds":{"any":"../Background/Background.icns"},"Set":"s3"},{"Id":"blackosx-set4b-lightgrey","Source":"blackosx","Group":"Set4b","Name":"LightGrey","Vendor":"Blackosx","Folder":"Set4b-LightGrey","Base":"Set4b/LightGrey","Backgrounds":{"any":"../Background/Background.icns"},"Set":"s3"},{"Id":"blackosx-set4b-orangered","Source":"blackosx","Group":"Set4b","Name":"OrangeRed","Vendor":"Blackosx","Folder":"Set4b-OrangeRed","Base":"Set4b/OrangeRed","Backgrounds":{"any":"../Background/Background.icns"},"Set":"s3"},{"Id":"blackosx-set4b-pinkpurple","Source":"blackosx","Group":"Set4b","Name":"PinkPurple","Vendor":"Blackosx","Folder":"Set4b-PinkPurple","Base":"Set4b/PinkPurple","Backgrounds":{"any":"../Background/Background.icns"},"Set":"s3"},{"Id":"blackosx-set4b-yellowgold","Source":"blackosx","Group":"Set4b","Name":"YellowGold","Vendor":"Blackosx","Folder":"Set4b-YellowGold","Base":"Set4b/YellowGold","Backgrounds":{"any":"../Background/Background.icns"},"Set":"s3"},{"Id":"blackosx-set4b-yelloworange","Source":"blackosx","Group":"Set4b","Name":"YellowOrange","Vendor":"Blackosx","Folder":"Set4b-YellowOrange","Base":"Set4b/YellowOrange","Backgrounds":{"any":"../Background/Background.icns"},"Set":"s3"},{"Id":"blackosx-set5 flattile-flattile-0","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_0","Vendor":"Blackosx","Folder":"Set5-FlatTile_0","Base":"Set5/FlatTile/FlatTile_0","Preview":"preview_sheet_FlatTile_0.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-108","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_108","Vendor":"Blackosx","Folder":"Set5-FlatTile_108","Base":"Set5/FlatTile/FlatTile_108","Preview":"preview_sheet_FlatTile_108.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-126","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_126","Vendor":"Blackosx","Folder":"Set5-FlatTile_126","Base":"Set5/FlatTile/FlatTile_126","Preview":"preview_sheet_FlatTile_126.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-144","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_144","Vendor":"Blackosx","Folder":"Set5-FlatTile_144","Base":"Set5/FlatTile/FlatTile_144","Preview":"preview_sheet_FlatTile_144.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-162","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_162","Vendor":"Blackosx","Folder":"Set5-FlatTile_162","Base":"Set5/FlatTile/FlatTile_162","Preview":"preview_sheet_FlatTile_162.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-18","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_18","Vendor":"Blackosx","Folder":"Set5-FlatTile_18","Base":"Set5/FlatTile/FlatTile_18","Preview":"preview_sheet_FlatTile_18.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-180","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_180","Vendor":"Blackosx","Folder":"Set5-FlatTile_180","Base":"Set5/FlatTile/FlatTile_180","Preview":"preview_sheet_FlatTile_180.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-198","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_198","Vendor":"Blackosx","Folder":"Set5-FlatTile_198","Base":"Set5/FlatTile/FlatTile_198","Preview":"preview_sheet_FlatTile_198.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-216","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_216","Vendor":"Blackosx","Folder":"Set5-FlatTile_216","Base":"Set5/FlatTile/FlatTile_216","Preview":"preview_sheet_FlatTile_216.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-234","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_234","Vendor":"Blackosx","Folder":"Set5-FlatTile_234","Base":"Set5/FlatTile/FlatTile_234","Preview":"preview_sheet_FlatTile_234.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-252","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_252","Vendor":"Blackosx","Folder":"Set5-FlatTile_252","Base":"Set5/FlatTile/FlatTile_252","Preview":"preview_sheet_FlatTile_252.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-270","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_270","Vendor":"Blackosx","Folder":"Set5-FlatTile_270","Base":"Set5/FlatTile/FlatTile_270","Preview":"preview_sheet_FlatTile_270.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-288","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_288","Vendor":"Blackosx","Folder":"Set5-FlatTile_288","Base":"Set5/FlatTile/FlatTile_288","Preview":"preview_sheet_FlatTile_288.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-306","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_306","Vendor":"Blackosx","Folder":"Set5-FlatTile_306","Base":"Set5/FlatTile/FlatTile_306","Preview":"preview_sheet_FlatTile_306.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-324","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_324","Vendor":"Blackosx","Folder":"Set5-FlatTile_324","Base":"Set5/FlatTile/FlatTile_324","Preview":"preview_sheet_FlatTile_324.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-342","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_342","Vendor":"Blackosx","Folder":"Set5-FlatTile_342","Base":"Set5/FlatTile/FlatTile_342","Preview":"preview_sheet_FlatTile_342.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-36","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_36","Vendor":"Blackosx","Folder":"Set5-FlatTile_36","Base":"Set5/FlatTile/FlatTile_36","Preview":"preview_sheet_FlatTile_36.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-54","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_54","Vendor":"Blackosx","Folder":"Set5-FlatTile_54","Base":"Set5/FlatTile/FlatTile_54","Preview":"preview_sheet_FlatTile_54.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-72","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_72","Vendor":"Blackosx","Folder":"Set5-FlatTile_72","Base":"Set5/FlatTile/FlatTile_72","Preview":"preview_sheet_FlatTile_72.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-90","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_90","Vendor":"Blackosx","Folder":"Set5-FlatTile_90","Base":"Set5/FlatTile/FlatTile_90","Preview":"preview_sheet_FlatTile_90.jpg","Set":"s4"},{"Id":"blackosx-set5 flattile-flattile-black","Source":"blackosx","Group":"Set5 FlatTile","Name":"FlatTile_Black","Vendor":"Blackosx","Folder":"Set5-FlatTile_Black","Base":"Set5/FlatTile/FlatTile_Black","Preview":"preview_sheet_FlatTile_Black.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-0","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_0","Vendor":"Blackosx","Folder":"Set5-Glassy_0","Base":"Set5/Glassy/Glassy_0","Preview":"preview_sheet_Glassy_0.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-105","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_105","Vendor":"Blackosx","Folder":"Set5-Glassy_105","Base":"Set5/Glassy/Glassy_105","Preview":"preview_sheet_Glassy_105.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-120","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_120","Vendor":"Blackosx","Folder":"Set5-Glassy_120","Base":"Set5/Glassy/Glassy_120","Preview":"preview_sheet_Glassy_120.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-135","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_135","Vendor":"Blackosx","Folder":"Set5-Glassy_135","Base":"Set5/Glassy/Glassy_135","Preview":"preview_sheet_Glassy_135.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-15","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_15","Vendor":"Blackosx","Folder":"Set5-Glassy_15","Base":"Set5/Glassy/Glassy_15","Preview":"preview_sheet_Glassy_15.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-150","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_150","Vendor":"Blackosx","Folder":"Set5-Glassy_150","Base":"Set5/Glassy/Glassy_150","Preview":"preview_sheet_Glassy_150.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-165","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_165","Vendor":"Blackosx","Folder":"Set5-Glassy_165","Base":"Set5/Glassy/Glassy_165","Preview":"preview_sheet_Glassy_165.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-180","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_180","Vendor":"Blackosx","Folder":"Set5-Glassy_180","Base":"Set5/Glassy/Glassy_180","Preview":"preview_sheet_Glassy_180.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-195","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_195","Vendor":"Blackosx","Folder":"Set5-Glassy_195","Base":"Set5/Glassy/Glassy_195","Preview":"preview_sheet_Glassy_195.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-210","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_210","Vendor":"Blackosx","Folder":"Set5-Glassy_210","Base":"Set5/Glassy/Glassy_210","Preview":"preview_sheet_Glassy_210.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-225","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_225","Vendor":"Blackosx","Folder":"Set5-Glassy_225","Base":"Set5/Glassy/Glassy_225","Preview":"preview_sheet_Glassy_225.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-240","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_240","Vendor":"Blackosx","Folder":"Set5-Glassy_240","Base":"Set5/Glassy/Glassy_240","Preview":"preview_sheet_Glassy_240.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-255","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_255","Vendor":"Blackosx","Folder":"Set5-Glassy_255","Base":"Set5/Glassy/Glassy_255","Preview":"preview_sheet_Glassy_255.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-270","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_270","Vendor":"Blackosx","Folder":"Set5-Glassy_270","Base":"Set5/Glassy/Glassy_270","Preview":"preview_sheet_Glassy_270.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-285","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_285","Vendor":"Blackosx","Folder":"Set5-Glassy_285","Base":"Set5/Glassy/Glassy_285","Preview":"preview_sheet_Glassy_285.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-30","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_30","Vendor":"Blackosx","Folder":"Set5-Glassy_30","Base":"Set5/Glassy/Glassy_30","Preview":"preview_sheet_Glassy_30.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-300","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_300","Vendor":"Blackosx","Folder":"Set5-Glassy_300","Base":"Set5/Glassy/Glassy_300","Preview":"preview_sheet_Glassy_300.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-315","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_315","Vendor":"Blackosx","Folder":"Set5-Glassy_315","Base":"Set5/Glassy/Glassy_315","Preview":"preview_sheet_Glassy_315.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-330","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_330","Vendor":"Blackosx","Folder":"Set5-Glassy_330","Base":"Set5/Glassy/Glassy_330","Preview":"preview_sheet_Glassy_330.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-345","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_345","Vendor":"Blackosx","Folder":"Set5-Glassy_345","Base":"Set5/Glassy/Glassy_345","Preview":"preview_sheet_Glassy_345.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-45","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_45","Vendor":"Blackosx","Folder":"Set5-Glassy_45","Base":"Set5/Glassy/Glassy_45","Preview":"preview_sheet_Glassy_45.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-60","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_60","Vendor":"Blackosx","Folder":"Set5-Glassy_60","Base":"Set5/Glassy/Glassy_60","Preview":"preview_sheet_Glassy_60.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-75","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_75","Vendor":"Blackosx","Folder":"Set5-Glassy_75","Base":"Set5/Glassy/Glassy_75","Preview":"preview_sheet_Glassy_75.jpg","Set":"s4"},{"Id":"blackosx-set5 glassy-glassy-90","Source":"blackosx","Group":"Set5 Glassy","Name":"Glassy_90","Vendor":"Blackosx","Folder":"Set5-Glassy_90","Base":"Set5/Glassy/Glassy_90","Preview":"preview_sheet_Glassy_90.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-0","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_0","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_0","Base":"Set5/GlassyTileIndent/GlassyTileIndent_0","Preview":"preview_sheet_GlassyTileIndent_0.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-108","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_108","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_108","Base":"Set5/GlassyTileIndent/GlassyTileIndent_108","Preview":"preview_sheet_GlassyTileIndent_108.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-126","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_126","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_126","Base":"Set5/GlassyTileIndent/GlassyTileIndent_126","Preview":"preview_sheet_GlassyTileIndent_126.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-144","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_144","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_144","Base":"Set5/GlassyTileIndent/GlassyTileIndent_144","Preview":"preview_sheet_GlassyTileIndent_144.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-162","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_162","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_162","Base":"Set5/GlassyTileIndent/GlassyTileIndent_162","Preview":"preview_sheet_GlassyTileIndent_162.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-18","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_18","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_18","Base":"Set5/GlassyTileIndent/GlassyTileIndent_18","Preview":"preview_sheet_GlassyTileIndent_18.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-180","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_180","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_180","Base":"Set5/GlassyTileIndent/GlassyTileIndent_180","Preview":"preview_sheet_GlassyTileIndent_180.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-198","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_198","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_198","Base":"Set5/GlassyTileIndent/GlassyTileIndent_198","Preview":"preview_sheet_GlassyTileIndent_198.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-216","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_216","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_216","Base":"Set5/GlassyTileIndent/GlassyTileIndent_216","Preview":"preview_sheet_GlassyTileIndent_216.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-234","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_234","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_234","Base":"Set5/GlassyTileIndent/GlassyTileIndent_234","Preview":"preview_sheet_GlassyTileIndent_234.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-252","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_252","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_252","Base":"Set5/GlassyTileIndent/GlassyTileIndent_252","Preview":"preview_sheet_GlassyTileIndent_252.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-270","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_270","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_270","Base":"Set5/GlassyTileIndent/GlassyTileIndent_270","Preview":"preview_sheet_GlassyTileIndent_270.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-288","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_288","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_288","Base":"Set5/GlassyTileIndent/GlassyTileIndent_288","Preview":"preview_sheet_GlassyTileIndent_288.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-306","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_306","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_306","Base":"Set5/GlassyTileIndent/GlassyTileIndent_306","Preview":"preview_sheet_GlassyTileIndent_306.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-324","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_324","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_324","Base":"Set5/GlassyTileIndent/GlassyTileIndent_324","Preview":"preview_sheet_GlassyTileIndent_324.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-342","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_342","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_342","Base":"Set5/GlassyTileIndent/GlassyTileIndent_342","Preview":"preview_sheet_GlassyTileIndent_342.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-36","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_36","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_36","Base":"Set5/GlassyTileIndent/GlassyTileIndent_36","Preview":"preview_sheet_GlassyTileIndent_36.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-54","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_54","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_54","Base":"Set5/GlassyTileIndent/GlassyTileIndent_54","Preview":"preview_sheet_GlassyTileIndent_54.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-72","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_72","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_72","Base":"Set5/GlassyTileIndent/GlassyTileIndent_72","Preview":"preview_sheet_GlassyTileIndent_72.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-90","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_90","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_90","Base":"Set5/GlassyTileIndent/GlassyTileIndent_90","Preview":"preview_sheet_GlassyTileIndent_90.jpg","Set":"s4"},{"Id":"blackosx-set5 glassytileindent-glassytileindent-black","Source":"blackosx","Group":"Set5 GlassyTileIndent","Name":"GlassyTileIndent_Black","Vendor":"Blackosx","Folder":"Set5-GlassyTileIndent_Black","Base":"Set5/GlassyTileIndent/GlassyTileIndent_Black","Preview":"preview_sheet_GlassyTileIndent_Black.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-0","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_0","Vendor":"Blackosx","Folder":"Set5-Marble_0","Base":"Set5/Marble/Marble_0","Preview":"preview_sheet_Marble_0.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-105","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_105","Vendor":"Blackosx","Folder":"Set5-Marble_105","Base":"Set5/Marble/Marble_105","Preview":"preview_sheet_Marble_105.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-120","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_120","Vendor":"Blackosx","Folder":"Set5-Marble_120","Base":"Set5/Marble/Marble_120","Preview":"preview_sheet_Marble_120.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-135","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_135","Vendor":"Blackosx","Folder":"Set5-Marble_135","Base":"Set5/Marble/Marble_135","Preview":"preview_sheet_Marble_135.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-15","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_15","Vendor":"Blackosx","Folder":"Set5-Marble_15","Base":"Set5/Marble/Marble_15","Preview":"preview_sheet_Marble_15.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-150","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_150","Vendor":"Blackosx","Folder":"Set5-Marble_150","Base":"Set5/Marble/Marble_150","Preview":"preview_sheet_Marble_150.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-165","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_165","Vendor":"Blackosx","Folder":"Set5-Marble_165","Base":"Set5/Marble/Marble_165","Preview":"preview_sheet_Marble_165.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-180","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_180","Vendor":"Blackosx","Folder":"Set5-Marble_180","Base":"Set5/Marble/Marble_180","Preview":"preview_sheet_Marble_180.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-195","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_195","Vendor":"Blackosx","Folder":"Set5-Marble_195","Base":"Set5/Marble/Marble_195","Preview":"preview_sheet_Marble_195.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-210","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_210","Vendor":"Blackosx","Folder":"Set5-Marble_210","Base":"Set5/Marble/Marble_210","Preview":"preview_sheet_Marble_210.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-225","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_225","Vendor":"Blackosx","Folder":"Set5-Marble_225","Base":"Set5/Marble/Marble_225","Preview":"preview_sheet_Marble_225.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-240","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_240","Vendor":"Blackosx","Folder":"Set5-Marble_240","Base":"Set5/Marble/Marble_240","Preview":"preview_sheet_Marble_240.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-255","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_255","Vendor":"Blackosx","Folder":"Set5-Marble_255","Base":"Set5/Marble/Marble_255","Preview":"preview_sheet_Marble_255.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-270","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_270","Vendor":"Blackosx","Folder":"Set5-Marble_270","Base":"Set5/Marble/Marble_270","Preview":"preview_sheet_Marble_270.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-285","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_285","Vendor":"Blackosx","Folder":"Set5-Marble_285","Base":"Set5/Marble/Marble_285","Preview":"preview_sheet_Marble_285.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-30","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_30","Vendor":"Blackosx","Folder":"Set5-Marble_30","Base":"Set5/Marble/Marble_30","Preview":"preview_sheet_Marble_30.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-300","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_300","Vendor":"Blackosx","Folder":"Set5-Marble_300","Base":"Set5/Marble/Marble_300","Preview":"preview_sheet_Marble_300.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-315","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_315","Vendor":"Blackosx","Folder":"Set5-Marble_315","Base":"Set5/Marble/Marble_315","Preview":"preview_sheet_Marble_315.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-330","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_330","Vendor":"Blackosx","Folder":"Set5-Marble_330","Base":"Set5/Marble/Marble_330","Preview":"preview_sheet_Marble_330.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-345","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_345","Vendor":"Blackosx","Folder":"Set5-Marble_345","Base":"Set5/Marble/Marble_345","Preview":"preview_sheet_Marble_345.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-45","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_45","Vendor":"Blackosx","Folder":"Set5-Marble_45","Base":"Set5/Marble/Marble_45","Preview":"preview_sheet_Marble_45.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-60","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_60","Vendor":"Blackosx","Folder":"Set5-Marble_60","Base":"Set5/Marble/Marble_60","Preview":"preview_sheet_Marble_60.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-75","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_75","Vendor":"Blackosx","Folder":"Set5-Marble_75","Base":"Set5/Marble/Marble_75","Preview":"preview_sheet_Marble_75.jpg","Set":"s4"},{"Id":"blackosx-set5 marble-marble-90","Source":"blackosx","Group":"Set5 Marble","Name":"Marble_90","Vendor":"Blackosx","Folder":"Set5-Marble_90","Base":"Set5/Marble/Marble_90","Preview":"preview_sheet_Marble_90.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-0","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_0","Vendor":"Blackosx","Folder":"Set5-WindowReflection_0","Base":"Set5/WindowReflection/WindowReflection_0","Preview":"preview_sheet_WindowReflection_0.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-105","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_105","Vendor":"Blackosx","Folder":"Set5-WindowReflection_105","Base":"Set5/WindowReflection/WindowReflection_105","Preview":"preview_sheet_WindowReflection_105.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-120","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_120","Vendor":"Blackosx","Folder":"Set5-WindowReflection_120","Base":"Set5/WindowReflection/WindowReflection_120","Preview":"preview_sheet_WindowReflection_120.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-135","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_135","Vendor":"Blackosx","Folder":"Set5-WindowReflection_135","Base":"Set5/WindowReflection/WindowReflection_135","Preview":"preview_sheet_WindowReflection_135.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-15","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_15","Vendor":"Blackosx","Folder":"Set5-WindowReflection_15","Base":"Set5/WindowReflection/WindowReflection_15","Preview":"preview_sheet_WindowReflection_15.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-150","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_150","Vendor":"Blackosx","Folder":"Set5-WindowReflection_150","Base":"Set5/WindowReflection/WindowReflection_150","Preview":"preview_sheet_WindowReflection_150.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-165","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_165","Vendor":"Blackosx","Folder":"Set5-WindowReflection_165","Base":"Set5/WindowReflection/WindowReflection_165","Preview":"preview_sheet_WindowReflection_165.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-180","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_180","Vendor":"Blackosx","Folder":"Set5-WindowReflection_180","Base":"Set5/WindowReflection/WindowReflection_180","Preview":"preview_sheet_WindowReflection_180.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-195","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_195","Vendor":"Blackosx","Folder":"Set5-WindowReflection_195","Base":"Set5/WindowReflection/WindowReflection_195","Preview":"preview_sheet_WindowReflection_195.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-210","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_210","Vendor":"Blackosx","Folder":"Set5-WindowReflection_210","Base":"Set5/WindowReflection/WindowReflection_210","Preview":"preview_sheet_WindowReflection_210.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-225","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_225","Vendor":"Blackosx","Folder":"Set5-WindowReflection_225","Base":"Set5/WindowReflection/WindowReflection_225","Preview":"preview_sheet_WindowReflection_225.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-240","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_240","Vendor":"Blackosx","Folder":"Set5-WindowReflection_240","Base":"Set5/WindowReflection/WindowReflection_240","Preview":"preview_sheet_WindowReflection_240.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-255","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_255","Vendor":"Blackosx","Folder":"Set5-WindowReflection_255","Base":"Set5/WindowReflection/WindowReflection_255","Preview":"preview_sheet_WindowReflection_255.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-270","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_270","Vendor":"Blackosx","Folder":"Set5-WindowReflection_270","Base":"Set5/WindowReflection/WindowReflection_270","Preview":"preview_sheet_WindowReflection_270.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-285","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_285","Vendor":"Blackosx","Folder":"Set5-WindowReflection_285","Base":"Set5/WindowReflection/WindowReflection_285","Preview":"preview_sheet_WindowReflection_285.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-30","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_30","Vendor":"Blackosx","Folder":"Set5-WindowReflection_30","Base":"Set5/WindowReflection/WindowReflection_30","Preview":"preview_sheet_WindowReflection_30.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-300","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_300","Vendor":"Blackosx","Folder":"Set5-WindowReflection_300","Base":"Set5/WindowReflection/WindowReflection_300","Preview":"preview_sheet_WindowReflection_300.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-315","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_315","Vendor":"Blackosx","Folder":"Set5-WindowReflection_315","Base":"Set5/WindowReflection/WindowReflection_315","Preview":"preview_sheet_WindowReflection_315.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-330","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_330","Vendor":"Blackosx","Folder":"Set5-WindowReflection_330","Base":"Set5/WindowReflection/WindowReflection_330","Preview":"preview_sheet_WindowReflection_330.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-345","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_345","Vendor":"Blackosx","Folder":"Set5-WindowReflection_345","Base":"Set5/WindowReflection/WindowReflection_345","Preview":"preview_sheet_WindowReflection_345.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-45","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_45","Vendor":"Blackosx","Folder":"Set5-WindowReflection_45","Base":"Set5/WindowReflection/WindowReflection_45","Preview":"preview_sheet_WindowReflection_45.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-60","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_60","Vendor":"Blackosx","Folder":"Set5-WindowReflection_60","Base":"Set5/WindowReflection/WindowReflection_60","Preview":"preview_sheet_WindowReflection_60.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-75","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_75","Vendor":"Blackosx","Folder":"Set5-WindowReflection_75","Base":"Set5/WindowReflection/WindowReflection_75","Preview":"preview_sheet_WindowReflection_75.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-90","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_90","Vendor":"Blackosx","Folder":"Set5-WindowReflection_90","Base":"Set5/WindowReflection/WindowReflection_90","Preview":"preview_sheet_WindowReflection_90.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-black","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_Black","Vendor":"Blackosx","Folder":"Set5-WindowReflection_Black","Base":"Set5/WindowReflection/WindowReflection_Black","Preview":"preview_sheet_WindowReflection_Black.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-bright-0","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_Bright_0","Vendor":"Blackosx","Folder":"Set5-WindowReflection_Bright_0","Base":"Set5/WindowReflection/WindowReflection_Bright_0","Preview":"preview_sheet_WindowReflection_Bright_0.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-bright-135","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_Bright_135","Vendor":"Blackosx","Folder":"Set5-WindowReflection_Bright_135","Base":"Set5/WindowReflection/WindowReflection_Bright_135","Preview":"preview_sheet_WindowReflection_Bright_135.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-bright-180","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_Bright_180","Vendor":"Blackosx","Folder":"Set5-WindowReflection_Bright_180","Base":"Set5/WindowReflection/WindowReflection_Bright_180","Preview":"preview_sheet_WindowReflection_Bright_180.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-bright-225","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_Bright_225","Vendor":"Blackosx","Folder":"Set5-WindowReflection_Bright_225","Base":"Set5/WindowReflection/WindowReflection_Bright_225","Preview":"preview_sheet_WindowReflection_Bright_225.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-bright-270","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_Bright_270","Vendor":"Blackosx","Folder":"Set5-WindowReflection_Bright_270","Base":"Set5/WindowReflection/WindowReflection_Bright_270","Preview":"preview_sheet_WindowReflection_Bright_270.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-bright-315","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_Bright_315","Vendor":"Blackosx","Folder":"Set5-WindowReflection_Bright_315","Base":"Set5/WindowReflection/WindowReflection_Bright_315","Preview":"preview_sheet_WindowReflection_Bright_315.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-bright-45","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_Bright_45","Vendor":"Blackosx","Folder":"Set5-WindowReflection_Bright_45","Base":"Set5/WindowReflection/WindowReflection_Bright_45","Preview":"preview_sheet_WindowReflection_Bright_45.jpg","Set":"s4"},{"Id":"blackosx-set5 windowreflection-windowreflection-bright-90","Source":"blackosx","Group":"Set5 WindowReflection","Name":"WindowReflection_Bright_90","Vendor":"Blackosx","Folder":"Set5-WindowReflection_Bright_90","Base":"Set5/WindowReflection/WindowReflection_Bright_90","Preview":"preview_sheet_WindowReflection_Bright_90.jpg","Set":"s4"},{"Id":"blackosx-set5 imac-imacblue","Source":"blackosx","Group":"Set5 iMac","Name":"iMacBlue","Vendor":"Blackosx","Folder":"Set5-iMacBlue","Base":"Set5/iMac/iMacBlue","Preview":"preview_sheet_iMacBlue.jpg","Set":"s4"},{"Id":"blackosx-set5 imac-imacgreen","Source":"blackosx","Group":"Set5 iMac","Name":"iMacGreen","Vendor":"Blackosx","Folder":"Set5-iMacGreen","Base":"Set5/iMac/iMacGreen","Preview":"preview_sheet_iMacGreen.jpg","Set":"s4"},{"Id":"blackosx-set5 imac-imacorange","Source":"blackosx","Group":"Set5 iMac","Name":"iMacOrange","Vendor":"Blackosx","Folder":"Set5-iMacOrange","Base":"Set5/iMac/iMacOrange","Preview":"preview_sheet_iMacOrange.jpg","Set":"s4"},{"Id":"blackosx-set5 imac-imacpink","Source":"blackosx","Group":"Set5 iMac","Name":"iMacPink","Vendor":"Blackosx","Folder":"Set5-iMacPink","Base":"Set5/iMac/iMacPink","Preview":"preview_sheet_iMacPink.jpg","Set":"s4"},{"Id":"blackosx-set5 imac-imacpurple","Source":"blackosx","Group":"Set5 iMac","Name":"iMacPurple","Vendor":"Blackosx","Folder":"Set5-iMacPurple","Base":"Set5/iMac/iMacPurple","Preview":"preview_sheet_iMacPurple.jpg","Set":"s4"},{"Id":"blackosx-set5 imac-imacsilver","Source":"blackosx","Group":"Set5 iMac","Name":"iMacSilver","Vendor":"Blackosx","Folder":"Set5-iMacSilver","Base":"Set5/iMac/iMacSilver","Preview":"preview_sheet_iMacSilver.jpg","Set":"s4"},{"Id":"blackosx-set5 imac-imacyellow","Source":"blackosx","Group":"Set5 iMac","Name":"iMacYellow","Vendor":"Blackosx","Folder":"Set5-iMacYellow","Base":"Set5/iMac/iMacYellow","Preview":"preview_sheet_iMacYellow.jpg","Set":"s4"}],"FileSets":{"s1":{"AppleRecv":"AppleRecv.icns","AppleTM":"AppleTM.icns","BtnFocus":"BtnFocus.icns","Cursor":"Cursor.icns","Dot":"Dot.icns","Enter":"Enter.icns","ExtAppleRecv":"ExtAppleRecv.icns","ExtAppleTM":"ExtAppleTM.icns","ExtHardDrive":"ExtHardDrive.icns","FirmwareSettings":"FirmwareSettings.icns","HardDrive":"HardDrive.icns","Left":"Left.icns","Lock":"Lock.icns","NetworkBoot":"NetworkBoot.icns","OpticalDrive":"OpticalDrive.icns","Password":"Password.icns","Restart":"Restart.icns","Right":"Right.icns","Selected":"Selected.icns","Selector":"Selector.icns","SetDefault":"SetDefault.icns","Shell":"Shell.icns","ShutDown":"ShutDown.icns","Tool":"Tool.icns","Windows":"Windows.icns"},"s2":{"Apple":"Apple.icns","AppleRecv":"AppleRecv.icns","AppleTM":"AppleTM.icns","BtnFocus":"BtnFocus.icns","Cursor":"Cursor.icns","Dot":"Dot.icns","Enter":"Enter.icns","ExtApple":"ExtApple.icns","ExtAppleRecv":"ExtAppleRecv.icns","ExtAppleTM":"ExtAppleTM.icns","ExtHardDrive":"ExtHardDrive.icns","HardDrive":"HardDrive.icns","Left":"Left.icns","Lock":"Lock.icns","Password":"Password.icns","ResetNVRAM":"ResetNVRAM.icns","Restart":"Restart.icns","Right":"Right.icns","Selected":"Selected.icns","Selector":"Selector.icns","SetDefault":"SetDefault.icns","Shell":"Shell.icns","ShutDown":"ShutDown.icns","Tool":"Tool.icns","Windows":"Windows10.icns"},"s3":{"Apple":"Apple.icns","AppleRecv":"AppleRecv.icns","AppleTM":"AppleTM.icns","BtnFocus":"BtnFocus.icns","Cursor":"Cursor.icns","Dot":"Dot.icns","Enter":"Enter.icns","HardDrive":"HardDrive.icns","Left":"Left.icns","Lock":"Lock.icns","Password":"Password.icns","ResetNVRAM":"ResetNVRAM.icns","Restart":"Restart.icns","Right":"Right.icns","Selected":"Selected.icns","Selector":"Selector.icns","SetDefault":"SetDefault.icns","Shell":"Shell.icns","ShutDown":"ShutDown.icns","Tool":"Tool.icns","Windows":"Windows.icns"},"s4":{"Apple":"Apple.icns","AppleRecv":"AppleRecv.icns","AppleTM":"AppleTM.icns","BtnFocus":"BtnFocus.icns","Cursor":"Cursor.icns","Dot":"Dot.icns","Enter":"Enter.icns","ExtApple":"ExtApple.icns","ExtAppleRecv":"ExtAppleRecv.icns","ExtAppleTM":"ExtAppleTM.icns","ExtHardDrive":"ExtHardDrive.icns","ExtWindows":"ExtWindows.icns","HardDrive":"HardDrive.icns","Left":"Left.icns","Lock":"Lock.icns","Password":"Password.icns","ResetNVRAM":"ResetNVRAM.icns","Restart":"Restart.icns","Right":"Right.icns","Selected":"Selected.icns","Selector":"Selector.icns","SetDefault":"SetDefault.icns","Shell":"Shell.icns","ShutDown":"ShutDown.icns","Tool":"Tool.icns","Windows":"Windows.icns"}}}
'@
$script:Catalog = $null

function Get-Catalog {
    if ($script:Catalog) { return $script:Catalog }
    $raw = $script:CatalogJson | ConvertFrom-Json
    $sources = @{}
    foreach ($src in $raw.Sources) { $sources[[string]$src.Id] = $src }
    $themes = @()
    foreach ($t in $raw.Themes) {
        if ($t.Set) { $fs = $raw.FileSets.PSObject.Properties[[string]$t.Set].Value } else { $fs = $t.Files }
        $files = [ordered]@{}
        foreach ($p in $fs.PSObject.Properties) { $files[[string]$p.Name] = [string]$p.Value }
        $bgs = @{}
        if ($t.Backgrounds) { foreach ($p in $t.Backgrounds.PSObject.Properties) { $bgs[[string]$p.Name] = [string]$p.Value } }
        $themes += [pscustomobject]@{
            Id = [string]$t.Id; Source = [string]$t.Source; Group = [string]$t.Group; Name = [string]$t.Name; Note = [string]$t.Note
            Vendor = [string]$t.Vendor; Folder = [string]$t.Folder; Base = [string]$t.Base
            Files = $files; Backgrounds = $bgs; Preview = [string]$t.Preview
        }
    }
    $script:Catalog = [pscustomobject]@{ Sources = $sources; Themes = $themes }
    return $script:Catalog
}

function Get-CatalogTheme([string]$Id) {
    foreach ($t in (Get-Catalog).Themes) { if ($t.Id -ceq $Id) { return $t } }
    return $null
}

function Get-CatalogUrl($Theme, [string]$Rel) {
    $src = (Get-Catalog).Sources[$Theme.Source]
    $segs = New-Object System.Collections.ArrayList
    foreach ($seg in (($Theme.Base + '/' + $Rel) -split '/')) {
        if ($seg -eq '' -or $seg -eq '.') { continue }
        if ($seg -eq '..') { if ($segs.Count -gt 0) { $segs.RemoveAt($segs.Count - 1) }; continue }
        [void]$segs.Add([Uri]::EscapeDataString($seg))
    }
    return ('https://raw.githubusercontent.com/{0}/{1}/{2}' -f $src.Repo, $src.Commit, ($segs -join '/'))
}

# Telechargement HTTPS limite aux hotes autorises, sans redirection, avec taille maximale.
function Get-UrlBytes([string]$Url, [int64]$MaxBytes) {
    $uri = New-Object System.Uri($Url)
    if ($uri.Scheme -ne 'https' -or ($script:AllowedHosts -notcontains $uri.Host)) { throw "Blocked URL: $Url" }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $req = [System.Net.WebRequest]::Create($uri)
    $req.Method = 'GET'
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 30000
    $req.AllowAutoRedirect = $false
    $req.UserAgent = 'OCDesigner'
    $resp = $req.GetResponse()
    try {
        if ([int]$resp.StatusCode -ne 200) { throw ('HTTP ' + [int]$resp.StatusCode) }
        if ($resp.ContentLength -gt $MaxBytes) { throw 'OCD_TOO_LARGE' }
        $in  = $resp.GetResponseStream()
        $ms  = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 81920
        while ($true) {
            $n = $in.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
            if ($ms.Length -gt $MaxBytes) { throw 'OCD_TOO_LARGE' }
        }
        return ,($ms.ToArray())
    } finally { $resp.Close() }
}

# Un .icns est accepte s'il est bien forme (longueur declaree exacte) et contient au moins un PNG.
function Test-IcnsBytes([byte[]]$Bytes) {
    if (-not $Bytes -or $Bytes.Length -lt 16) { return $false }
    if ([Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -ne 'icns') { return $false }
    if ((Read-BigEndianInt $Bytes 4) -ne $Bytes.Length) { return $false }
    $chunks = Read-IcnsBytes $Bytes
    foreach ($k in $chunks.Keys) { if (Test-PngBytes $chunks[$k]) { return $true } }
    return $false
}

function Get-CatalogFile($Theme, [string]$Rel, [bool]$IsIcns, [int64]$MaxBytes) {
    $url  = Get-CatalogUrl $Theme $Rel
    $sha  = [Security.Cryptography.SHA1]::Create()
    $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($url))).Replace('-', '')
    $sha.Dispose()
    $file = Join-Path $script:CacheRoot ($hash + '.bin')
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        $cached = [IO.File]::ReadAllBytes($file)
        if (-not $IsIcns -or (Test-IcnsBytes $cached)) { return ,$cached }
    }
    $bytes = Get-UrlBytes $url $MaxBytes
    if ($IsIcns -and -not (Test-IcnsBytes $bytes)) { throw ('OCD_BAD_ICNS:' + $Rel) }
    if (-not (Test-Path -LiteralPath $script:CacheRoot)) { [void](New-Item -ItemType Directory -Path $script:CacheRoot -Force) }
    [IO.File]::WriteAllBytes($file, $bytes)
    return ,$bytes
}

# Fond d'ecran propose par le theme pour une resolution d'ecran donnee (ou $null).
function Select-CatalogBackground($Theme, [int]$ScreenW, [int]$ScreenH) {
    $bgs = $Theme.Backgrounds
    if (-not $bgs -or $bgs.Count -eq 0) { return $null }
    if ($bgs.ContainsKey('any')) { return $bgs['any'] }
    $exact = '{0}x{1}' -f $ScreenW, $ScreenH
    if ($bgs.ContainsKey($exact)) { return $bgs[$exact] }
    # les fonds contiennent aussi l'image 2x : un fond 1920x1080 convient a un ecran 3840x2160
    $half = '{0}x{1}' -f [int]($ScreenW / 2), [int]($ScreenH / 2)
    if ($bgs.ContainsKey($half)) { return $bgs[$half] }
    $best = $null; $bestArea = 0
    foreach ($k in $bgs.Keys) {
        if ($k -match '^(\d+)x(\d+)$') {
            $area = [int]$Matches[1] * [int]$Matches[2]
            if ($area -gt $bestArea) { $bestArea = $area; $best = $bgs[$k] }
        }
    }
    return $best
}

function Get-CatalogPlan($Theme, [bool]$IncludeBackground, [int]$ScreenW, [int]$ScreenH) {
    $plan = @()
    $hasBg = $false
    foreach ($slot in $Theme.Files.Keys) {
        if ($slot -eq 'Background') {
            if (-not $IncludeBackground) { continue }
            $hasBg = $true
        }
        $plan += [pscustomobject]@{ Name = ($slot + '.icns'); Rel = [string]$Theme.Files[$slot] }
    }
    if ($IncludeBackground -and -not $hasBg) {
        $bg = Select-CatalogBackground $Theme $ScreenW $ScreenH
        if ($bg) { $plan += [pscustomobject]@{ Name = 'Background.icns'; Rel = $bg } }
    }
    return $plan
}

function Get-CatalogThemeRel($Theme) { return ($Theme.Vendor + '\' + $Theme.Folder) }

# Telecharge, verifie puis installe un theme du catalogue dans Resources\Image\<Auteur>\<Theme>.
function Install-CatalogTheme([string]$EfiOc, $Theme, [bool]$IncludeBackground, [int]$ScreenW, [int]$ScreenH, [scriptblock]$OnProgress) {
    if (-not (Test-ThemeName $Theme.Folder) -or -not (Test-ThemeName $Theme.Vendor)) { throw 'OCD_BAD_NAME' }
    $plan = @(Get-CatalogPlan $Theme $IncludeBackground $ScreenW $ScreenH)
    $data = [ordered]@{}
    $i = 0
    foreach ($item in $plan) {
        $i++
        if ($OnProgress) { & $OnProgress $i $plan.Count $item.Name }
        $data[$item.Name] = Get-CatalogFile $Theme $item.Rel $true $script:MaxIcnsBytes
    }
    # icones d'interface manquantes : reprises du theme GoldenGate (local, sinon officiel en ligne)
    $completed = @()
    $refDir = Get-ThemeDir $EfiOc 'Acidanthera\GoldenGate'
    $ref = Get-CatalogTheme 'acidanthera-GoldenGate'
    foreach ($slot in $script:SupportIcons) {
        $name = $slot + '.icns'
        if ($data.Contains($name)) { continue }
        $local = Join-Path $refDir $name
        if (Test-Path -LiteralPath $local -PathType Leaf) {
            $b = [IO.File]::ReadAllBytes($local)
            if (Test-IcnsBytes $b) { $data[$name] = $b; $completed += $slot; continue }
        }
        if ($ref -and $ref.Files.Contains($slot)) {
            $data[$name] = Get-CatalogFile $ref ([string]$ref.Files[$slot]) $true $script:MaxIcnsBytes
            $completed += $slot
        }
    }
    $themeRel = Get-CatalogThemeRel $Theme
    $total = [int64]0
    $rels = @()
    foreach ($name in $data.Keys) {
        $total += ([byte[]]$data[$name]).Length
        $rels += (Join-Path (Join-Path 'Resources\Image' $themeRel) $name)
    }
    Assert-FreeSpace $EfiOc $total
    $backupId = New-Backup $EfiOc 'install-theme' $rels
    $dstDir = Get-ThemeDir $EfiOc $themeRel
    if (-not (Test-Path -LiteralPath $dstDir)) { [void](New-Item -ItemType Directory -Path $dstDir -Force) }
    foreach ($name in $data.Keys) { [IO.File]::WriteAllBytes((Join-Path $dstDir $name), [byte[]]$data[$name]) }
    return [pscustomobject]@{ ThemeRel = $themeRel; Count = $data.Count; Completed = $completed; Bytes = $total; BackupId = $backupId }
}

if ($NoGui) { return }

# =============================================================================================
#  INTERFACE
# =============================================================================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Data

# Erreur fatale au demarrage : on l'affiche au lieu de fermer silencieusement.
trap {
    Write-Log ("FATAL " + $_.Exception.Message + "`n" + $_.ScriptStackTrace)
    if (-not $SelfTest) {
        [void][System.Windows.MessageBox]::Show(($_.Exception.Message + "`n`n" + $_.ScriptStackTrace), 'OC Designer', 'OK', 'Error')
    }
    break
}

# ---------------------------------------------------------------------------------------------
#  Traductions (FR / EN / NL)
# ---------------------------------------------------------------------------------------------
$script:Strings = @{}
$script:Strings['fr'] = @{
    navStyle = 'Style du menu'; navTheme = 'Thème et fond'; navOptions = 'Options'; navBackups = 'Sauvegardes'
    navCatalog = 'Catalogue en ligne'
    catTrust = 'Deux sources uniquement : le dépôt officiel Acidanthera et celui de Blackosx, cité par la documentation d''OpenCore. Téléchargement en HTTPS depuis une version figée ; chaque fichier .icns est vérifié avant installation.'
    catAll = 'Toutes les sources'; catAllGroups = 'Toutes les collections'; catInstalled = 'installé'
    catInfo = '{0} · {1} fichiers · source : {2} (version {3})'; catNoSel = 'Sélectionnez un thème.'
    catIncludeBg = 'Inclure le fond d''écran du thème quand il en propose un (résolution choisie dans « Thème et fond »)'
    catApply = 'Installer et appliquer'; catInstall = 'Installer seulement'; catPreview = 'Voir l''aperçu'; catOpenSource = 'Page de la source'
    catDownloading = 'Téléchargement {0}/{1} : {2}'; catDone = 'Thème installé : {0} ({1} fichiers, {2}).'
    catCompleted = ' Icônes d''interface reprises de GoldenGate : {0}.'
    catApplyNow = 'Le thème {0} est installé et sélectionné, avec le menu graphique. Enregistrer config.plist maintenant ?'
    catBadFile = 'Fichier refusé (ce n''est pas un .icns valide) : {0}'; catTooLarge = 'Fichier trop volumineux, téléchargement annulé.'
    catNetError = 'Téléchargement impossible. Vérifiez la connexion Internet.'
    'r_install-theme' = 'Thème du catalogue'
    efiFolder = 'Dossier EFI\OC'; browse = 'Parcourir…'; reload = 'Recharger'; language = 'Langue'
    save = 'Enregistrer'; revert = 'Annuler les modifications'
    cardMode = 'Type de menu'
    modeBuiltin = 'Texte (Builtin)'; modeBuiltinDesc = 'Menu texte simple, toujours disponible.'
    modeExternal = 'Graphique (OpenCanopy)'; modeExternalDesc = 'Icônes, fond d''écran et souris. Nécessite OpenCanopy.efi.'
    modeApple = 'Sélecteur Apple'; modeAppleDesc = 'Sélecteur natif Apple, sur matériel compatible uniquement.'
    canopyOk = 'OpenCanopy : installé et déclaré.'
    canopyWillDeclare = 'OpenCanopy.efi est présent ; il sera déclaré dans config.plist à l''enregistrement.'
    canopyMissing = 'OpenCanopy.efi est absent de Drivers : OpenCore reviendra au menu texte.'
    canopyNoRes = 'Le dossier Resources (Image, Label, Font) est incomplet.'
    canopyInstall = 'Installer OpenCanopy.efi…'; canopyGet = 'Télécharger OpenCore'
    canopyPick = 'Choisir OpenCanopy.efi (même version qu''OpenCore, dossier X64\EFI\OC\Drivers)'
    canopyInstalled = 'OpenCanopy.efi copié dans Drivers. Enregistrez pour le déclarer dans config.plist.'
    cardDisplay = 'Affichage'; uiScale = 'Échelle de l''interface'; resolution = 'Résolution'; textRenderer = 'Rendu du texte'
    scaleKeep = 'Inchangée (-1)'; scaleAuto = 'Automatique (0)'; scale1 = '1x - écran standard'; scale2 = '2x - HiDPI'
    cardConsole = 'Couleurs du menu texte'; conFg = 'Texte'; conBg = 'Fond'
    cardAttrs = 'Comportement du menu'
    attr1 = 'Utiliser l''icône propre à chaque volume (.VolumeIcon.icns)'
    attr2 = 'Utiliser les libellés pré-rendus des disques (.disk_label)'
    attr4 = 'Libellés génériques prédéfinis'
    attr8 = 'Préférer les icônes du thème (nécessite l''icône de volume)'
    attr16 = 'Activer la souris / le trackpad'
    attr64 = 'Interface minimale (sans Éteindre / Redémarrer)'
    attr128 = 'Icônes selon le type de système (flavour)'
    attr256 = 'Inverser Éteindre et Redémarrer'
    attr512 = 'Réduire les animations'
    cardVariant = 'Thème d''icônes'; variant = 'Thème (PickerVariant)'
    variantAuto = 'Auto (selon la couleur de fond)'; variantDefault = 'Défaut (GoldenGate)'
    effTheme = 'Thème utilisé : {0}'; effThemeMissing = 'Thème utilisé : {0} - dossier introuvable dans Resources\Image'
    dupTheme = 'Dupliquer…'; importTheme = 'Importer un dossier…'; openTheme = 'Ouvrir le dossier'; getThemes = 'Trouver des thèmes'
    cardBg = 'Fond'; bgColor = 'Couleur de fond'; bgBlack = 'Noir'; bgGray = 'Gris clair'; bgApply = 'Appliquer'
    bgImage = 'Image de fond'; bgSet = 'Choisir une image…'; bgRemove = 'Retirer l''image'; bgRes = 'Résolution de l''écran'
    bgNone = 'Aucune image de fond dans ce thème.'; bgInfo = 'Image actuelle : {0} × {1} px'
    cardIcons = 'Icônes (cliquer pour remplacer par un PNG)'
    fileOpsNote = 'Les fichiers du thème sont modifiés immédiatement, avec sauvegarde automatique.'
    cardBoot = 'Affichage du menu'; showPicker = 'Afficher le menu à chaque démarrage'
    timeout = 'Délai avant démarrage automatique (secondes, 0 = attendre)'
    hideAux = 'Masquer les entrées auxiliaires (Recovery, Reset NVRAM…) - Espace pour les afficher'
    cardKeys = 'Clavier et accessibilité'; hotKeys = 'Raccourcis Apple au démarrage (Cmd+R, Cmd+V…)'
    audioAssist = 'Assistance vocale dans le menu'; allowDefault = 'Autoriser le choix du disque par défaut (Ctrl+Entrée)'
    takeoff = 'Délai avant lecture des touches (microsecondes)'
    cardMisc = 'Démarrage'; hibSkip = 'Ne pas afficher le menu au réveil d''hibernation'
    verbose = 'Démarrage verbeux de macOS (-v) au lieu du logo Apple'
    notInConfig = 'absent de ce config.plist'
    preview = 'Aperçu'; previewScreen = 'Écran simulé'
    previewNote = 'Aperçu indicatif : la disposition réelle dépend du firmware et de la version d''OpenCore.'
    previewApple = 'Sélecteur Apple natif - pas d''aperçu'
    previewHidden = 'Menu masqué au démarrage (maintenir Échap pour l''afficher)'
    backupsInfo = 'Chaque écriture est précédée d''une sauvegarde. Emplacement : {0}'
    colDate = 'Date'; colType = 'Type'; colReason = 'Origine'; colFiles = 'Fichiers'; colSize = 'Taille'
    kindAuto = 'Ciblée'; kindFull = 'Complète'
    backupFull = 'Sauvegarde complète de l''EFI'; restore = 'Restaurer'; deleteBackup = 'Supprimer'; openBackups = 'Ouvrir le dossier'
    'r_save' = 'Enregistrement'; 'r_set-background' = 'Changement du fond'; 'r_remove-background' = 'Retrait du fond'
    'r_set-icon' = 'Remplacement d''icône'; 'r_duplicate-theme' = 'Duplication de thème'; 'r_import-theme' = 'Import de thème'
    'r_install-opencanopy' = 'Installation d''OpenCanopy'; 'r_before-restore' = 'Avant restauration'; 'r_manual' = 'Manuelle'
    stReady = 'Prêt.'; stLoaded = 'Chargé : {0}'; stSaved = 'Enregistré. Sauvegarde : {0}'; stModified = 'Modifications non enregistrées : {0}'
    stFree = 'Espace libre : {0}'; stReformat = 'La mise en forme du fichier sera normalisée au premier enregistrement.'
    stBackupDone = 'Sauvegarde créée : {0}'; stRestored = 'Sauvegarde restaurée.'; stNoEfi = 'Aucun dossier EFI\OC ouvert.'
    msgNoEfi = 'Aucun config.plist trouvé dans ce dossier.'
    msgPickEfi = 'Sélectionnez le dossier EFI\OC (celui qui contient config.plist)'
    msgUnsaved = 'Des modifications ne sont pas enregistrées. Les abandonner ?'
    msgChanged = 'config.plist a été modifié par un autre programme depuis son ouverture. Recharger le fichier ? (vos réglages en cours seront perdus)'
    msgRestore = 'Restaurer cette sauvegarde dans {0} ? L''état actuel sera sauvegardé avant.'
    msgRestoreOther = 'Attention : cette sauvegarde provient de {0}.'
    msgDelete = 'Supprimer définitivement cette sauvegarde ?'
    msgRemoveBg = 'Retirer l''image de fond du thème {0} ?'
    msgThemeName = 'Nom du nouveau thème (lettres, chiffres, tirets) :'
    msgBadName = 'Nom invalide : utilisez uniquement lettres, chiffres, tirets et traits bas.'
    msgExists = 'Un thème portant ce nom existe déjà.'
    msgNoIcns = 'Ce dossier ne contient aucun fichier .icns.'
    msgNoSpace = 'Espace libre insuffisant sur la partition EFI.'
    msgAccess = 'Accès refusé. Relancez l''éditeur en tant qu''administrateur, ou vérifiez que la partition EFI est montée en écriture.'
    msgRunAdmin = 'Relancer en tant qu''administrateur maintenant ?'
    msgNvram = 'Pour que la couleur ou les arguments de démarrage soient pris en compte, un Reset NVRAM peut être nécessaire au prochain démarrage.'
    msgCanopyAdded = 'OpenCanopy.efi a été ajouté à UEFI > Drivers.'
    msgThemeCreated = 'Thème créé : {0}. Il est sélectionné ; enregistrez pour l''utiliser.'
    msgBadColor = 'Couleur invalide. Format attendu : #RRGGBB'
    msgImgFilter = 'Images|*.png;*.jpg;*.jpeg;*.bmp'; msgPngFilter = 'Images PNG|*.png'
    error = 'Erreur'; confirm = 'Confirmation'; ok = 'OK'; cancel = 'Annuler'
    col0 = 'Noir'; col1 = 'Bleu'; col2 = 'Vert'; col3 = 'Cyan'; col4 = 'Rouge'; col5 = 'Magenta'; col6 = 'Brun'; col7 = 'Gris clair'
    col8 = 'Gris foncé'; col9 = 'Bleu clair'; col10 = 'Vert clair'; col11 = 'Cyan clair'; col12 = 'Rouge clair'; col13 = 'Magenta clair'; col14 = 'Jaune'; col15 = 'Blanc'
}
$script:Strings['en'] = @{
    navStyle = 'Menu style'; navTheme = 'Theme and background'; navOptions = 'Options'; navBackups = 'Backups'
    navCatalog = 'Online catalogue'
    catTrust = 'Two sources only: the official Acidanthera repository and Blackosx''s, which the OpenCore documentation refers to. Downloaded over HTTPS from a pinned version; every .icns file is checked before installation.'
    catAll = 'All sources'; catAllGroups = 'All collections'; catInstalled = 'installed'
    catInfo = '{0} · {1} files · source: {2} (version {3})'; catNoSel = 'Select a theme.'
    catIncludeBg = 'Include the theme''s background when it offers one (resolution chosen under "Theme and background")'
    catApply = 'Install and apply'; catInstall = 'Install only'; catPreview = 'View preview'; catOpenSource = 'Source page'
    catDownloading = 'Downloading {0}/{1}: {2}'; catDone = 'Theme installed: {0} ({1} files, {2}).'
    catCompleted = ' Interface icons taken from GoldenGate: {0}.'
    catApplyNow = 'Theme {0} is installed and selected, with the graphical menu. Save config.plist now?'
    catBadFile = 'File rejected (not a valid .icns): {0}'; catTooLarge = 'File too large, download cancelled.'
    catNetError = 'Download failed. Check the Internet connection.'
    'r_install-theme' = 'Catalogue theme'
    efiFolder = 'EFI\OC folder'; browse = 'Browse…'; reload = 'Reload'; language = 'Language'
    save = 'Save'; revert = 'Discard changes'
    cardMode = 'Menu type'
    modeBuiltin = 'Text (Builtin)'; modeBuiltinDesc = 'Simple text menu, always available.'
    modeExternal = 'Graphical (OpenCanopy)'; modeExternalDesc = 'Icons, background and mouse. Requires OpenCanopy.efi.'
    modeApple = 'Apple picker'; modeAppleDesc = 'Native Apple picker, on compatible hardware only.'
    canopyOk = 'OpenCanopy: installed and declared.'
    canopyWillDeclare = 'OpenCanopy.efi is present; it will be declared in config.plist when you save.'
    canopyMissing = 'OpenCanopy.efi is missing from Drivers: OpenCore will fall back to the text menu.'
    canopyNoRes = 'The Resources folder (Image, Label, Font) is incomplete.'
    canopyInstall = 'Install OpenCanopy.efi…'; canopyGet = 'Download OpenCore'
    canopyPick = 'Select OpenCanopy.efi (same version as OpenCore, folder X64\EFI\OC\Drivers)'
    canopyInstalled = 'OpenCanopy.efi copied to Drivers. Save to declare it in config.plist.'
    cardDisplay = 'Display'; uiScale = 'Interface scale'; resolution = 'Resolution'; textRenderer = 'Text renderer'
    scaleKeep = 'Unchanged (-1)'; scaleAuto = 'Automatic (0)'; scale1 = '1x - standard display'; scale2 = '2x - HiDPI'
    cardConsole = 'Text menu colours'; conFg = 'Text'; conBg = 'Background'
    cardAttrs = 'Menu behaviour'
    attr1 = 'Use each volume''s own icon (.VolumeIcon.icns)'
    attr2 = 'Use prerendered disk labels (.disk_label)'
    attr4 = 'Predefined generic labels'
    attr8 = 'Prefer theme icons (requires volume icon)'
    attr16 = 'Enable mouse / trackpad'
    attr64 = 'Minimal interface (no Shut Down / Restart)'
    attr128 = 'Icons by system type (flavour)'
    attr256 = 'Swap Shut Down and Restart'
    attr512 = 'Reduce motion'
    cardVariant = 'Icon theme'; variant = 'Theme (PickerVariant)'
    variantAuto = 'Auto (from background colour)'; variantDefault = 'Default (GoldenGate)'
    effTheme = 'Theme in use: {0}'; effThemeMissing = 'Theme in use: {0} - folder not found in Resources\Image'
    dupTheme = 'Duplicate…'; importTheme = 'Import a folder…'; openTheme = 'Open folder'; getThemes = 'Find themes'
    cardBg = 'Background'; bgColor = 'Background colour'; bgBlack = 'Black'; bgGray = 'Light gray'; bgApply = 'Apply'
    bgImage = 'Background image'; bgSet = 'Choose an image…'; bgRemove = 'Remove image'; bgRes = 'Screen resolution'
    bgNone = 'No background image in this theme.'; bgInfo = 'Current image: {0} × {1} px'
    cardIcons = 'Icons (click to replace with a PNG)'
    fileOpsNote = 'Theme files are changed immediately, with an automatic backup.'
    cardBoot = 'Menu display'; showPicker = 'Show the menu at every boot'
    timeout = 'Delay before automatic boot (seconds, 0 = wait)'
    hideAux = 'Hide auxiliary entries (Recovery, Reset NVRAM…) - Space shows them'
    cardKeys = 'Keyboard and accessibility'; hotKeys = 'Apple boot shortcuts (Cmd+R, Cmd+V…)'
    audioAssist = 'Voice assistance in the menu'; allowDefault = 'Allow choosing the default disk (Ctrl+Enter)'
    takeoff = 'Delay before reading keys (microseconds)'
    cardMisc = 'Boot'; hibSkip = 'Skip the menu when waking from hibernation'
    verbose = 'Verbose macOS boot (-v) instead of the Apple logo'
    notInConfig = 'not in this config.plist'
    preview = 'Preview'; previewScreen = 'Simulated screen'
    previewNote = 'Indicative preview: the real layout depends on the firmware and the OpenCore version.'
    previewApple = 'Native Apple picker - no preview'
    previewHidden = 'Menu hidden at boot (hold Esc to show it)'
    backupsInfo = 'Every write is preceded by a backup. Location: {0}'
    colDate = 'Date'; colType = 'Type'; colReason = 'Origin'; colFiles = 'Files'; colSize = 'Size'
    kindAuto = 'Targeted'; kindFull = 'Full'
    backupFull = 'Full EFI backup'; restore = 'Restore'; deleteBackup = 'Delete'; openBackups = 'Open folder'
    'r_save' = 'Save'; 'r_set-background' = 'Background change'; 'r_remove-background' = 'Background removal'
    'r_set-icon' = 'Icon replacement'; 'r_duplicate-theme' = 'Theme duplication'; 'r_import-theme' = 'Theme import'
    'r_install-opencanopy' = 'OpenCanopy install'; 'r_before-restore' = 'Before restore'; 'r_manual' = 'Manual'
    stReady = 'Ready.'; stLoaded = 'Loaded: {0}'; stSaved = 'Saved. Backup: {0}'; stModified = 'Unsaved changes: {0}'
    stFree = 'Free space: {0}'; stReformat = 'The file formatting will be normalised on first save.'
    stBackupDone = 'Backup created: {0}'; stRestored = 'Backup restored.'; stNoEfi = 'No EFI\OC folder open.'
    msgNoEfi = 'No config.plist found in this folder.'
    msgPickEfi = 'Select the EFI\OC folder (the one containing config.plist)'
    msgUnsaved = 'There are unsaved changes. Discard them?'
    msgChanged = 'config.plist was changed by another program since it was opened. Reload the file? (your current settings will be lost)'
    msgRestore = 'Restore this backup into {0}? The current state will be backed up first.'
    msgRestoreOther = 'Warning: this backup comes from {0}.'
    msgDelete = 'Permanently delete this backup?'
    msgRemoveBg = 'Remove the background image from theme {0}?'
    msgThemeName = 'Name of the new theme (letters, digits, dashes):'
    msgBadName = 'Invalid name: use only letters, digits, dashes and underscores.'
    msgExists = 'A theme with this name already exists.'
    msgNoIcns = 'This folder contains no .icns file.'
    msgNoSpace = 'Not enough free space on the EFI partition.'
    msgAccess = 'Access denied. Restart the editor as administrator, or check that the EFI partition is mounted read-write.'
    msgRunAdmin = 'Restart as administrator now?'
    msgNvram = 'For the colour or boot arguments to take effect, an NVRAM reset may be needed at next boot.'
    msgCanopyAdded = 'OpenCanopy.efi was added to UEFI > Drivers.'
    msgThemeCreated = 'Theme created: {0}. It is selected; save to use it.'
    msgBadColor = 'Invalid colour. Expected format: #RRGGBB'
    msgImgFilter = 'Images|*.png;*.jpg;*.jpeg;*.bmp'; msgPngFilter = 'PNG images|*.png'
    error = 'Error'; confirm = 'Confirmation'; ok = 'OK'; cancel = 'Cancel'
    col0 = 'Black'; col1 = 'Blue'; col2 = 'Green'; col3 = 'Cyan'; col4 = 'Red'; col5 = 'Magenta'; col6 = 'Brown'; col7 = 'Light gray'
    col8 = 'Dark gray'; col9 = 'Light blue'; col10 = 'Light green'; col11 = 'Light cyan'; col12 = 'Light red'; col13 = 'Light magenta'; col14 = 'Yellow'; col15 = 'White'
}
$script:Strings['nl'] = @{
    navStyle = 'Menustijl'; navTheme = 'Thema en achtergrond'; navOptions = 'Opties'; navBackups = 'Back-ups'
    navCatalog = 'Online catalogus'
    catTrust = 'Slechts twee bronnen: de officiële Acidanthera-repository en die van Blackosx, waarnaar de OpenCore-documentatie verwijst. Download via HTTPS van een vastgezette versie; elk .icns-bestand wordt vóór installatie gecontroleerd.'
    catAll = 'Alle bronnen'; catAllGroups = 'Alle collecties'; catInstalled = 'geïnstalleerd'
    catInfo = '{0} · {1} bestanden · bron: {2} (versie {3})'; catNoSel = 'Selecteer een thema.'
    catIncludeBg = 'Achtergrond van het thema meenemen als het er een aanbiedt (resolutie gekozen onder "Thema en achtergrond")'
    catApply = 'Installeren en toepassen'; catInstall = 'Alleen installeren'; catPreview = 'Voorbeeld bekijken'; catOpenSource = 'Pagina van de bron'
    catDownloading = 'Downloaden {0}/{1}: {2}'; catDone = 'Thema geïnstalleerd: {0} ({1} bestanden, {2}).'
    catCompleted = ' Interfacepictogrammen overgenomen van GoldenGate: {0}.'
    catApplyNow = 'Thema {0} is geïnstalleerd en geselecteerd, met het grafische menu. config.plist nu opslaan?'
    catBadFile = 'Bestand geweigerd (geen geldig .icns): {0}'; catTooLarge = 'Bestand te groot, download geannuleerd.'
    catNetError = 'Download mislukt. Controleer de internetverbinding.'
    'r_install-theme' = 'Catalogusthema'
    efiFolder = 'Map EFI\OC'; browse = 'Bladeren…'; reload = 'Herladen'; language = 'Taal'
    save = 'Opslaan'; revert = 'Wijzigingen annuleren'
    cardMode = 'Menutype'
    modeBuiltin = 'Tekst (Builtin)'; modeBuiltinDesc = 'Eenvoudig tekstmenu, altijd beschikbaar.'
    modeExternal = 'Grafisch (OpenCanopy)'; modeExternalDesc = 'Pictogrammen, achtergrond en muis. Vereist OpenCanopy.efi.'
    modeApple = 'Apple-kiezer'; modeAppleDesc = 'Systeemeigen Apple-kiezer, alleen op compatibele hardware.'
    canopyOk = 'OpenCanopy: geïnstalleerd en gedeclareerd.'
    canopyWillDeclare = 'OpenCanopy.efi is aanwezig; het wordt bij het opslaan in config.plist gedeclareerd.'
    canopyMissing = 'OpenCanopy.efi ontbreekt in Drivers: OpenCore valt terug op het tekstmenu.'
    canopyNoRes = 'De map Resources (Image, Label, Font) is onvolledig.'
    canopyInstall = 'OpenCanopy.efi installeren…'; canopyGet = 'OpenCore downloaden'
    canopyPick = 'Kies OpenCanopy.efi (zelfde versie als OpenCore, map X64\EFI\OC\Drivers)'
    canopyInstalled = 'OpenCanopy.efi gekopieerd naar Drivers. Sla op om het in config.plist te declareren.'
    cardDisplay = 'Weergave'; uiScale = 'Schaal van de interface'; resolution = 'Resolutie'; textRenderer = 'Tekstweergave'
    scaleKeep = 'Ongewijzigd (-1)'; scaleAuto = 'Automatisch (0)'; scale1 = '1x - standaardscherm'; scale2 = '2x - HiDPI'
    cardConsole = 'Kleuren van het tekstmenu'; conFg = 'Tekst'; conBg = 'Achtergrond'
    cardAttrs = 'Gedrag van het menu'
    attr1 = 'Eigen pictogram van elk volume gebruiken (.VolumeIcon.icns)'
    attr2 = 'Vooraf gerenderde schijflabels gebruiken (.disk_label)'
    attr4 = 'Vooraf gedefinieerde algemene labels'
    attr8 = 'Themapictogrammen verkiezen (vereist volumepictogram)'
    attr16 = 'Muis / trackpad inschakelen'
    attr64 = 'Minimale interface (zonder Zet uit / Herstart)'
    attr128 = 'Pictogrammen volgens systeemtype (flavour)'
    attr256 = 'Zet uit en Herstart omwisselen'
    attr512 = 'Animaties verminderen'
    cardVariant = 'Pictogramthema'; variant = 'Thema (PickerVariant)'
    variantAuto = 'Auto (volgens achtergrondkleur)'; variantDefault = 'Standaard (GoldenGate)'
    effTheme = 'Gebruikt thema: {0}'; effThemeMissing = 'Gebruikt thema: {0} - map niet gevonden in Resources\Image'
    dupTheme = 'Dupliceren…'; importTheme = 'Map importeren…'; openTheme = 'Map openen'; getThemes = 'Thema''s zoeken'
    cardBg = 'Achtergrond'; bgColor = 'Achtergrondkleur'; bgBlack = 'Zwart'; bgGray = 'Lichtgrijs'; bgApply = 'Toepassen'
    bgImage = 'Achtergrondafbeelding'; bgSet = 'Afbeelding kiezen…'; bgRemove = 'Afbeelding verwijderen'; bgRes = 'Schermresolutie'
    bgNone = 'Geen achtergrondafbeelding in dit thema.'; bgInfo = 'Huidige afbeelding: {0} × {1} px'
    cardIcons = 'Pictogrammen (klik om door een PNG te vervangen)'
    fileOpsNote = 'Themabestanden worden onmiddellijk gewijzigd, met automatische back-up.'
    cardBoot = 'Weergave van het menu'; showPicker = 'Menu bij elke opstart tonen'
    timeout = 'Wachttijd voor automatisch opstarten (seconden, 0 = wachten)'
    hideAux = 'Hulpitems verbergen (Recovery, Reset NVRAM…) - spatie toont ze'
    cardKeys = 'Toetsenbord en toegankelijkheid'; hotKeys = 'Apple-sneltoetsen bij opstarten (Cmd+R, Cmd+V…)'
    audioAssist = 'Spraakondersteuning in het menu'; allowDefault = 'Keuze van de standaardschijf toestaan (Ctrl+Enter)'
    takeoff = 'Wachttijd voor het lezen van toetsen (microseconden)'
    cardMisc = 'Opstarten'; hibSkip = 'Menu overslaan bij ontwaken uit sluimerstand'
    verbose = 'Uitgebreide macOS-opstart (-v) in plaats van het Apple-logo'
    notInConfig = 'niet aanwezig in deze config.plist'
    preview = 'Voorbeeld'; previewScreen = 'Gesimuleerd scherm'
    previewNote = 'Indicatief voorbeeld: de echte lay-out hangt af van de firmware en de OpenCore-versie.'
    previewApple = 'Systeemeigen Apple-kiezer - geen voorbeeld'
    previewHidden = 'Menu verborgen bij opstarten (Esc ingedrukt houden om het te tonen)'
    backupsInfo = 'Elke schrijfbewerking wordt voorafgegaan door een back-up. Locatie: {0}'
    colDate = 'Datum'; colType = 'Type'; colReason = 'Oorsprong'; colFiles = 'Bestanden'; colSize = 'Grootte'
    kindAuto = 'Gericht'; kindFull = 'Volledig'
    backupFull = 'Volledige back-up van de EFI'; restore = 'Herstellen'; deleteBackup = 'Verwijderen'; openBackups = 'Map openen'
    'r_save' = 'Opslaan'; 'r_set-background' = 'Achtergrond gewijzigd'; 'r_remove-background' = 'Achtergrond verwijderd'
    'r_set-icon' = 'Pictogram vervangen'; 'r_duplicate-theme' = 'Thema gedupliceerd'; 'r_import-theme' = 'Thema geïmporteerd'
    'r_install-opencanopy' = 'OpenCanopy geïnstalleerd'; 'r_before-restore' = 'Vóór herstel'; 'r_manual' = 'Handmatig'
    stReady = 'Gereed.'; stLoaded = 'Geladen: {0}'; stSaved = 'Opgeslagen. Back-up: {0}'; stModified = 'Niet-opgeslagen wijzigingen: {0}'
    stFree = 'Vrije ruimte: {0}'; stReformat = 'De opmaak van het bestand wordt bij de eerste keer opslaan genormaliseerd.'
    stBackupDone = 'Back-up gemaakt: {0}'; stRestored = 'Back-up hersteld.'; stNoEfi = 'Geen map EFI\OC geopend.'
    msgNoEfi = 'Geen config.plist gevonden in deze map.'
    msgPickEfi = 'Selecteer de map EFI\OC (die config.plist bevat)'
    msgUnsaved = 'Er zijn niet-opgeslagen wijzigingen. Verwerpen?'
    msgChanged = 'config.plist is sinds het openen door een ander programma gewijzigd. Bestand herladen? (uw huidige instellingen gaan verloren)'
    msgRestore = 'Deze back-up herstellen naar {0}? De huidige toestand wordt eerst opgeslagen.'
    msgRestoreOther = 'Let op: deze back-up komt van {0}.'
    msgDelete = 'Deze back-up definitief verwijderen?'
    msgRemoveBg = 'De achtergrondafbeelding van thema {0} verwijderen?'
    msgThemeName = 'Naam van het nieuwe thema (letters, cijfers, streepjes):'
    msgBadName = 'Ongeldige naam: gebruik alleen letters, cijfers, streepjes en underscores.'
    msgExists = 'Er bestaat al een thema met deze naam.'
    msgNoIcns = 'Deze map bevat geen .icns-bestand.'
    msgNoSpace = 'Onvoldoende vrije ruimte op de EFI-partitie.'
    msgAccess = 'Toegang geweigerd. Start de editor opnieuw als administrator, of controleer of de EFI-partitie schrijfbaar is gekoppeld.'
    msgRunAdmin = 'Nu opnieuw starten als administrator?'
    msgNvram = 'Opdat de kleur of de opstartargumenten van kracht worden, kan bij de volgende opstart een NVRAM-reset nodig zijn.'
    msgCanopyAdded = 'OpenCanopy.efi is toegevoegd aan UEFI > Drivers.'
    msgThemeCreated = 'Thema gemaakt: {0}. Het is geselecteerd; sla op om het te gebruiken.'
    msgBadColor = 'Ongeldige kleur. Verwacht formaat: #RRGGBB'
    msgImgFilter = 'Afbeeldingen|*.png;*.jpg;*.jpeg;*.bmp'; msgPngFilter = 'PNG-afbeeldingen|*.png'
    error = 'Fout'; confirm = 'Bevestiging'; ok = 'OK'; cancel = 'Annuleren'
    col0 = 'Zwart'; col1 = 'Blauw'; col2 = 'Groen'; col3 = 'Cyaan'; col4 = 'Rood'; col5 = 'Magenta'; col6 = 'Bruin'; col7 = 'Lichtgrijs'
    col8 = 'Donkergrijs'; col9 = 'Lichtblauw'; col10 = 'Lichtgroen'; col11 = 'Lichtcyaan'; col12 = 'Lichtrood'; col13 = 'Lichtmagenta'; col14 = 'Geel'; col15 = 'Wit'
}

$script:Lang = 'en'
function T([string]$Key) {
    $v = $script:Strings[$script:Lang][$Key]
    if (-not $v) { $v = $script:Strings['en'][$Key] }
    if (-not $v) { $v = $Key }
    if ($args.Count -gt 0) { return ($v -f $args) }
    return $v
}

# ---------------------------------------------------------------------------------------------
#  Fenetre (XAML)
# ---------------------------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OC Designer" Width="1280" Height="800" MinWidth="1080" MinHeight="660"
        WindowStartupLocation="CenterScreen" Background="#F2F3F5" FontFamily="Segoe UI" FontSize="13"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#0F766E"/>
    <SolidColorBrush x:Key="Ink" Color="#1F2933"/>
    <SolidColorBrush x:Key="Muted" Color="#667085"/>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#1F2933"/>
      <Setter Property="BorderBrush" Value="#CBD2D9"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.82"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#0F766E"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#0F766E"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Tile" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Padding" Value="4"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="Width" Value="86"/>
      <Setter Property="Height" Value="86"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#E1E4E8"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="16,14"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#1F2933"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="Lbl" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#3E4C59"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#667085"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Margin" Value="0,4,0,4"/>
      <Setter Property="Foreground" Value="#1F2933"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="Margin" Value="0,3,0,3"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Padding" Value="5,4"/>
      <Setter Property="Margin" Value="0,3,0,3"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- En-tete -->
    <Border Grid.Row="0" Background="#FFFFFF" BorderBrush="#E1E4E8" BorderThickness="0,0,0,1" Padding="18,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="OC Designer" FontSize="18" FontWeight="Bold" Foreground="#0F766E" VerticalAlignment="Center" Margin="0,0,22,0"/>
        <TextBlock Grid.Column="1" Tag="t:efiFolder" Style="{StaticResource Lbl}"/>
        <TextBox Grid.Column="2" x:Name="txtEfi" IsReadOnly="True" Background="#F7F8FA" Margin="0,0,8,0"/>
        <Button Grid.Column="3" x:Name="btnBrowse" Tag="t:browse" Style="{StaticResource Btn}"/>
        <Button Grid.Column="4" x:Name="btnReload" Tag="t:reload" Style="{StaticResource Btn}"/>
        <ComboBox Grid.Column="5" x:Name="cmbLang" Width="110" Margin="8,0,0,0">
          <ComboBoxItem Content="Français" Tag="fr"/>
          <ComboBoxItem Content="English" Tag="en"/>
          <ComboBoxItem Content="Nederlands" Tag="nl"/>
        </ComboBox>
      </Grid>
    </Border>

    <!-- Corps -->
    <Grid Grid.Row="1" Margin="18,14,18,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="170"/>
        <ColumnDefinition Width="470"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <ListBox Grid.Column="0" x:Name="lstNav" Background="Transparent" BorderThickness="0" Margin="0,0,12,0" FontSize="14">
        <ListBox.ItemContainerStyle>
          <Style TargetType="ListBoxItem">
            <Setter Property="Padding" Value="12,10"/>
            <Setter Property="Margin" Value="0,0,0,4"/>
            <Setter Property="Cursor" Value="Hand"/>
          </Style>
        </ListBox.ItemContainerStyle>
        <ListBoxItem Tag="t:navStyle"/>
        <ListBoxItem Tag="t:navTheme"/>
        <ListBoxItem Tag="t:navCatalog"/>
        <ListBoxItem Tag="t:navOptions"/>
        <ListBoxItem Tag="t:navBackups"/>
      </ListBox>

      <Grid Grid.Column="1" Margin="0,0,14,0">
        <!-- Page : style -->
        <ScrollViewer x:Name="pageStyle" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="0,0,6,0">
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Tag="t:cardMode" Style="{StaticResource CardTitle}"/>
                <RadioButton x:Name="rbBuiltin" GroupName="mode" Margin="0,2,0,0"><TextBlock Tag="t:modeBuiltin" FontWeight="SemiBold"/></RadioButton>
                <TextBlock Tag="t:modeBuiltinDesc" Style="{StaticResource Hint}" Margin="20,0,0,8"/>
                <RadioButton x:Name="rbExternal" GroupName="mode"><TextBlock Tag="t:modeExternal" FontWeight="SemiBold"/></RadioButton>
                <TextBlock Tag="t:modeExternalDesc" Style="{StaticResource Hint}" Margin="20,0,0,8"/>
                <RadioButton x:Name="rbApple" GroupName="mode"><TextBlock Tag="t:modeApple" FontWeight="SemiBold"/></RadioButton>
                <TextBlock Tag="t:modeAppleDesc" Style="{StaticResource Hint}" Margin="20,0,0,10"/>
                <Border x:Name="bdCanopy" Background="#F0FDFA" BorderBrush="#99D5CC" BorderThickness="1" CornerRadius="6" Padding="10,8">
                  <StackPanel>
                    <TextBlock x:Name="txtCanopy" TextWrapping="Wrap" Foreground="#1F2933"/>
                    <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                      <Button x:Name="btnCanopyInstall" Tag="t:canopyInstall" Style="{StaticResource Btn}"/>
                      <Button x:Name="btnCanopyGet" Tag="t:canopyGet" Style="{StaticResource Btn}"/>
                    </StackPanel>
                  </StackPanel>
                </Border>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Tag="t:cardDisplay" Style="{StaticResource CardTitle}"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Tag="t:uiScale" Style="{StaticResource Lbl}"/>
                  <ComboBox Grid.Row="0" Grid.Column="1" x:Name="cmbUIScale"/>
                  <TextBlock Grid.Row="1" Tag="t:resolution" Style="{StaticResource Lbl}"/>
                  <ComboBox Grid.Row="1" Grid.Column="1" x:Name="cmbResolution" IsEditable="True"/>
                  <TextBlock Grid.Row="2" Tag="t:textRenderer" Style="{StaticResource Lbl}"/>
                  <ComboBox Grid.Row="2" Grid.Column="1" x:Name="cmbTextRenderer"/>
                </Grid>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Tag="t:cardConsole" Style="{StaticResource CardTitle}"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Tag="t:conFg" Style="{StaticResource Lbl}"/>
                  <ComboBox Grid.Row="0" Grid.Column="1" x:Name="cmbConFg"/>
                  <TextBlock Grid.Row="1" Tag="t:conBg" Style="{StaticResource Lbl}"/>
                  <ComboBox Grid.Row="1" Grid.Column="1" x:Name="cmbConBg"/>
                </Grid>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Tag="t:cardAttrs" Style="{StaticResource CardTitle}"/>
                <StackPanel x:Name="pnlAttrs"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- Page : theme -->
        <ScrollViewer x:Name="pageTheme" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel Margin="0,0,6,0">
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Tag="t:cardVariant" Style="{StaticResource CardTitle}"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <TextBlock Tag="t:variant" Style="{StaticResource Lbl}"/>
                  <ComboBox Grid.Column="1" x:Name="cmbVariant"/>
                </Grid>
                <TextBlock x:Name="txtEffTheme" Style="{StaticResource Hint}" Margin="0,4,0,10"/>
                <WrapPanel>
                  <Button x:Name="btnDupTheme" Tag="t:dupTheme" Style="{StaticResource Btn}" Margin="0,0,8,6"/>
                  <Button x:Name="btnImportTheme" Tag="t:importTheme" Style="{StaticResource Btn}" Margin="0,0,8,6"/>
                  <Button x:Name="btnOpenTheme" Tag="t:openTheme" Style="{StaticResource Btn}" Margin="0,0,8,6"/>
                  <Button x:Name="btnGetThemes" Tag="t:getThemes" Style="{StaticResource Btn}" Margin="0,0,8,6"/>
                </WrapPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Tag="t:cardBg" Style="{StaticResource CardTitle}"/>
                <TextBlock Tag="t:bgColor" Style="{StaticResource Lbl}" Margin="0,0,0,4"/>
                <StackPanel Orientation="Horizontal">
                  <Border x:Name="bdSwatch" Width="30" Height="30" CornerRadius="6" BorderBrush="#CBD2D9" BorderThickness="1" Margin="0,0,8,0"/>
                  <TextBox x:Name="txtBgHex" Width="90" MaxLength="7" Margin="0,0,8,0"/>
                  <Button x:Name="btnBgApply" Tag="t:bgApply" Style="{StaticResource Btn}"/>
                  <Button x:Name="btnBgBlack" Tag="t:bgBlack" Style="{StaticResource Btn}"/>
                  <Button x:Name="btnBgGray" Tag="t:bgGray" Style="{StaticResource Btn}"/>
                </StackPanel>
                <WrapPanel x:Name="pnlSwatches" Margin="0,8,0,0"/>
                <TextBlock Tag="t:bgImage" Style="{StaticResource Lbl}" Margin="0,14,0,4"/>
                <TextBlock x:Name="txtBgInfo" Style="{StaticResource Hint}" Margin="0,0,0,6"/>
                <Grid Margin="0,0,0,6">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <TextBlock Tag="t:bgRes" Style="{StaticResource Lbl}"/>
                  <ComboBox Grid.Column="1" x:Name="cmbBgRes"/>
                </Grid>
                <StackPanel Orientation="Horizontal">
                  <Button x:Name="btnBgSet" Tag="t:bgSet" Style="{StaticResource Btn}"/>
                  <Button x:Name="btnBgRemove" Tag="t:bgRemove" Style="{StaticResource Btn}"/>
                </StackPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Tag="t:cardIcons" Style="{StaticResource CardTitle}"/>
                <WrapPanel x:Name="pnlIcons"/>
                <TextBlock Tag="t:fileOpsNote" Style="{StaticResource Hint}" Margin="0,6,0,0"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- Page : catalogue en ligne -->
        <Grid x:Name="pageCatalog" Visibility="Collapsed">
          <Border Style="{StaticResource Card}" Margin="0">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <TextBlock Grid.Row="0" Tag="t:navCatalog" Style="{StaticResource CardTitle}"/>
              <TextBlock Grid.Row="1" Tag="t:catTrust" Style="{StaticResource Hint}" Margin="0,0,0,10"/>
              <Grid Grid.Row="2">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <ComboBox Grid.Column="0" x:Name="cmbCatSource"/>
                <ComboBox Grid.Column="2" x:Name="cmbCatGroup"/>
              </Grid>
              <ListBox Grid.Row="3" x:Name="lstCatalog" BorderBrush="#E1E4E8" Margin="0,6,0,8"/>
              <TextBlock Grid.Row="4" x:Name="txtCatInfo" Style="{StaticResource Hint}" Margin="0,0,0,6"/>
              <CheckBox Grid.Row="5" x:Name="chkCatBg" IsChecked="True"><TextBlock Tag="t:catIncludeBg" TextWrapping="Wrap"/></CheckBox>
              <StackPanel Grid.Row="6" Margin="0,6,0,0">
                <ProgressBar x:Name="pbCat" Height="6" Minimum="0" Maximum="1" Value="0"/>
                <TextBlock x:Name="txtCatStatus" Style="{StaticResource Hint}" Margin="0,4,0,0"/>
              </StackPanel>
              <WrapPanel Grid.Row="7" Margin="0,10,0,0">
                <Button x:Name="btnCatApply" Tag="t:catApply" Style="{StaticResource BtnPrimary}" Margin="0,0,8,6"/>
                <Button x:Name="btnCatInstall" Tag="t:catInstall" Style="{StaticResource Btn}" Margin="0,0,8,6"/>
                <Button x:Name="btnCatPreview" Tag="t:catPreview" Style="{StaticResource Btn}" Margin="0,0,8,6"/>
                <Button x:Name="btnCatSource" Tag="t:catOpenSource" Style="{StaticResource Btn}" Margin="0,0,8,6"/>
              </WrapPanel>
            </Grid>
          </Border>
        </Grid>

        <!-- Page : options -->
        <ScrollViewer x:Name="pageOptions" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
          <StackPanel Margin="0,0,6,0">
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Tag="t:cardBoot" Style="{StaticResource CardTitle}"/>
                <CheckBox x:Name="chkShowPicker"><TextBlock Tag="t:showPicker" TextWrapping="Wrap"/></CheckBox>
                <CheckBox x:Name="chkHideAux"><TextBlock Tag="t:hideAux" TextWrapping="Wrap"/></CheckBox>
                <Grid Margin="0,6,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/></Grid.ColumnDefinitions>
                  <TextBlock Tag="t:timeout" Style="{StaticResource Lbl}"/>
                  <TextBox Grid.Column="1" x:Name="txtTimeout" MaxLength="5"/>
                </Grid>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Tag="t:cardKeys" Style="{StaticResource CardTitle}"/>
                <CheckBox x:Name="chkHotKeys"><TextBlock Tag="t:hotKeys" TextWrapping="Wrap"/></CheckBox>
                <CheckBox x:Name="chkAllowDefault"><TextBlock Tag="t:allowDefault" TextWrapping="Wrap"/></CheckBox>
                <CheckBox x:Name="chkAudioAssist"><TextBlock Tag="t:audioAssist" TextWrapping="Wrap"/></CheckBox>
                <Grid Margin="0,6,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/></Grid.ColumnDefinitions>
                  <TextBlock Tag="t:takeoff" Style="{StaticResource Lbl}"/>
                  <TextBox Grid.Column="1" x:Name="txtTakeoff" MaxLength="8"/>
                </Grid>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Tag="t:cardMisc" Style="{StaticResource CardTitle}"/>
                <CheckBox x:Name="chkVerbose"><TextBlock Tag="t:verbose" TextWrapping="Wrap"/></CheckBox>
                <CheckBox x:Name="chkHibSkip"><TextBlock Tag="t:hibSkip" TextWrapping="Wrap"/></CheckBox>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- Page : sauvegardes -->
        <Grid x:Name="pageBackups" Visibility="Collapsed">
          <Border Style="{StaticResource Card}" Margin="0">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <TextBlock Grid.Row="0" Tag="t:navBackups" Style="{StaticResource CardTitle}"/>
              <TextBlock Grid.Row="1" x:Name="txtBackupInfo" Style="{StaticResource Hint}" Margin="0,0,0,10"/>
              <ListView Grid.Row="2" x:Name="lvBackups" SelectionMode="Single" BorderBrush="#E1E4E8">
                <ListView.View>
                  <GridView>
                    <GridViewColumn x:Name="colDate" Width="128" DisplayMemberBinding="{Binding Date}"/>
                    <GridViewColumn x:Name="colType" Width="68" DisplayMemberBinding="{Binding Type}"/>
                    <GridViewColumn x:Name="colReason" Width="138" DisplayMemberBinding="{Binding Reason}"/>
                    <GridViewColumn x:Name="colFiles" Width="52" DisplayMemberBinding="{Binding Files}"/>
                    <GridViewColumn x:Name="colSize" Width="64" DisplayMemberBinding="{Binding Size}"/>
                  </GridView>
                </ListView.View>
              </ListView>
              <WrapPanel Grid.Row="3" Margin="0,12,0,0">
                <Button x:Name="btnBackupFull" Tag="t:backupFull" Style="{StaticResource BtnPrimary}" Margin="0,0,8,6"/>
                <Button x:Name="btnRestore" Tag="t:restore" Style="{StaticResource Btn}" Margin="0,0,8,6"/>
                <Button x:Name="btnDeleteBackup" Tag="t:deleteBackup" Style="{StaticResource Btn}" Margin="0,0,8,6"/>
                <Button x:Name="btnOpenBackups" Tag="t:openBackups" Style="{StaticResource Btn}" Margin="0,0,8,6"/>
              </WrapPanel>
            </Grid>
          </Border>
        </Grid>
      </Grid>

      <!-- Apercu -->
      <Grid Grid.Column="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid Grid.Row="0" Margin="0,0,0,8">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock Tag="t:preview" FontSize="14" FontWeight="SemiBold" Foreground="#1F2933" VerticalAlignment="Center"/>
          <TextBlock Grid.Column="1" Tag="t:previewScreen" Style="{StaticResource Lbl}"/>
          <ComboBox Grid.Column="2" x:Name="cmbPreviewRes" Width="130" Margin="0"/>
        </Grid>
        <Border Grid.Row="1" Background="#101114" CornerRadius="10" Padding="10" ClipToBounds="True">
          <Viewbox Stretch="Uniform">
            <Border BorderBrush="#2A2D34" BorderThickness="2">
              <Canvas x:Name="cnvPreview" Width="1920" Height="1080" ClipToBounds="True" Background="#000000"/>
            </Border>
          </Viewbox>
        </Border>
        <TextBlock Grid.Row="2" Tag="t:previewNote" Style="{StaticResource Hint}" Margin="0,8,0,0"/>
      </Grid>
    </Grid>

    <!-- Pied -->
    <Border Grid.Row="2" Background="#FFFFFF" BorderBrush="#E1E4E8" BorderThickness="0,1,0,0" Padding="18,10">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock x:Name="txtStatus" Foreground="#3E4C59" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        <Button Grid.Column="1" x:Name="btnRevert" Tag="t:revert" Style="{StaticResource Btn}"/>
        <Button Grid.Column="2" x:Name="btnSave" Tag="t:save" Style="{StaticResource BtnPrimary}" Margin="0" Padding="22,7"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$script:Win = [Windows.Markup.XamlReader]::Parse($xaml)
$script:UI = @{}
foreach ($name in @('txtEfi', 'btnBrowse', 'btnReload', 'cmbLang', 'lstNav', 'pageStyle', 'pageTheme', 'pageOptions', 'pageBackups',
        'rbBuiltin', 'rbExternal', 'rbApple', 'bdCanopy', 'txtCanopy', 'btnCanopyInstall', 'btnCanopyGet',
        'cmbUIScale', 'cmbResolution', 'cmbTextRenderer', 'cmbConFg', 'cmbConBg', 'pnlAttrs',
        'cmbVariant', 'txtEffTheme', 'btnDupTheme', 'btnImportTheme', 'btnOpenTheme', 'btnGetThemes',
        'bdSwatch', 'txtBgHex', 'btnBgApply', 'btnBgBlack', 'btnBgGray', 'pnlSwatches', 'txtBgInfo', 'cmbBgRes', 'btnBgSet', 'btnBgRemove', 'pnlIcons',
        'chkShowPicker', 'chkHideAux', 'txtTimeout', 'chkHotKeys', 'chkAllowDefault', 'chkAudioAssist', 'txtTakeoff', 'chkVerbose', 'chkHibSkip',
        'txtBackupInfo', 'lvBackups', 'colDate', 'colType', 'colReason', 'colFiles', 'colSize',
        'btnBackupFull', 'btnRestore', 'btnDeleteBackup', 'btnOpenBackups',
        'pageCatalog', 'cmbCatSource', 'cmbCatGroup', 'lstCatalog', 'txtCatInfo', 'chkCatBg', 'pbCat', 'txtCatStatus',
        'btnCatApply', 'btnCatInstall', 'btnCatPreview', 'btnCatSource',
        'cmbPreviewRes', 'cnvPreview', 'txtStatus', 'btnRevert', 'btnSave')) {
    $script:UI[$name] = $script:Win.FindName($name)
    if (-not $script:UI[$name]) { throw "UI element not found: $name" }
}

$script:Ctx      = $null      # @{ EfiOc; Plist; Orig; State }
$script:Loading  = $false
$script:ImgCache = @{}
$script:AttrChecks = @()
$script:Settings = Read-Settings

# ---------------------------------------------------------------------------------------------
#  Boites de dialogue
# ---------------------------------------------------------------------------------------------
function Show-Info([string]$Message) {
    Write-Log "INFO  $Message"
    if ($SelfTest) { return }
    [void][System.Windows.MessageBox]::Show($script:Win, $Message, $script:AppName, 'OK', 'Information')
}

function Show-Confirm([string]$Message) {
    if ($SelfTest) { return $true }
    $r = [System.Windows.MessageBox]::Show($script:Win, $Message, (T 'confirm'), 'YesNo', 'Question')
    return ($r -eq 'Yes')
}

function Get-FriendlyError($ErrorRecord) {
    $ex = $ErrorRecord.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    $msg = [string]$ex.Message
    if ($msg -eq 'OCD_NO_SPACE') { return (T 'msgNoSpace') }
    if ($msg -eq 'OCD_BAD_NAME') { return (T 'msgBadName') }
    if ($msg -eq 'OCD_EXISTS')   { return (T 'msgExists') }
    if ($msg -eq 'OCD_NO_ICNS')  { return (T 'msgNoIcns') }
    if ($msg -eq 'OCD_TOO_LARGE') { return (T 'catTooLarge') }
    if ($msg.StartsWith('OCD_BAD_ICNS:')) { return (T 'catBadFile' $msg.Substring(13)) }
    if ($ex -is [System.Net.WebException]) { return ((T 'catNetError') + "`n`n" + $msg) }
    if ($ex -is [System.UnauthorizedAccessException]) { return ((T 'msgAccess') + "`n`n" + $msg) }
    return $msg
}

function Show-Error($ErrorRecord) {
    $text = Get-FriendlyError $ErrorRecord
    Write-Log ("ERROR $text`n" + $ErrorRecord.ScriptStackTrace)
    if ($SelfTest) { return }
    $ex = $ErrorRecord.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    if ($ex -is [System.UnauthorizedAccessException]) {
        $r = [System.Windows.MessageBox]::Show($script:Win, ($text + "`n`n" + (T 'msgRunAdmin')), (T 'error'), 'YesNo', 'Warning')
        if ($r -eq 'Yes') { Restart-Elevated }
        return
    }
    [void][System.Windows.MessageBox]::Show($script:Win, $text, (T 'error'), 'OK', 'Error')
}

function Invoke-Safe([scriptblock]$Block) {
    try { & $Block } catch { Show-Error $_ }
}

function Restart-Elevated {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"' + $PSCommandPath + '"'))
    if ($script:Ctx) { $argList += @('-EfiPath', ('"' + $script:Ctx.EfiOc + '"')) }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
        $script:ForceClose = $true
        $script:Win.Close()
    } catch { }
}

function Show-InputBox([string]$Title, [string]$Label, [string]$Default) {
    $w = New-Object System.Windows.Window
    $w.Title = $Title; $w.Width = 420; $w.SizeToContent = 'Height'; $w.ResizeMode = 'NoResize'
    $w.WindowStartupLocation = 'CenterOwner'; $w.Owner = $script:Win; $w.Background = [System.Windows.Media.Brushes]::White
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = '16'
    $lb = New-Object System.Windows.Controls.TextBlock; $lb.Text = $Label; $lb.TextWrapping = 'Wrap'; $lb.Margin = '0,0,0,8'
    $tb = New-Object System.Windows.Controls.TextBox; $tb.Text = $Default; $tb.Padding = '5,4'
    $bp = New-Object System.Windows.Controls.StackPanel; $bp.Orientation = 'Horizontal'; $bp.HorizontalAlignment = 'Right'; $bp.Margin = '0,14,0,0'
    $ok = New-Object System.Windows.Controls.Button; $ok.Content = (T 'ok'); $ok.IsDefault = $true; $ok.Style = $script:Win.FindResource('BtnPrimary'); $ok.MinWidth = 80
    $ca = New-Object System.Windows.Controls.Button; $ca.Content = (T 'cancel'); $ca.IsCancel = $true; $ca.Style = $script:Win.FindResource('Btn'); $ca.MinWidth = 80; $ca.Margin = '0'
    $ok.Add_Click({ param($s, $e) [System.Windows.Window]::GetWindow($s).DialogResult = $true })
    [void]$bp.Children.Add($ok); [void]$bp.Children.Add($ca)
    [void]$sp.Children.Add($lb); [void]$sp.Children.Add($tb); [void]$sp.Children.Add($bp)
    $w.Content = $sp
    [void]$tb.Focus(); $tb.SelectAll()
    if ($w.ShowDialog()) { return $tb.Text.Trim() }
    return $null
}

# ---------------------------------------------------------------------------------------------
#  Images
# ---------------------------------------------------------------------------------------------
function ConvertTo-Bitmap([byte[]]$Bytes) {
    $ms = New-Object System.IO.MemoryStream(, $Bytes)
    try {
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        $bi.BeginInit()
        $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bi.StreamSource = $ms
        $bi.EndInit()
        $bi.Freeze()
        return $bi
    } finally { $ms.Dispose() }
}

function Read-ImageFile([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    return (ConvertTo-Bitmap $bytes)
}

# Redimensionne une image en PNG. Mode 'Cover' : remplit et rogne ; 'Contain' : ajuste sur fond transparent.
function ConvertTo-PngBytes($Source, [int]$Width, [int]$Height, [string]$Mode) {
    $pw = [double]$Source.PixelWidth; $ph = [double]$Source.PixelHeight
    if ($Mode -eq 'Cover') { $k = [Math]::Max($Width / $pw, $Height / $ph) } else { $k = [Math]::Min($Width / $pw, $Height / $ph) }
    $dw = $pw * $k; $dh = $ph * $k
    $rect = New-Object System.Windows.Rect((($Width - $dw) / 2), (($Height - $dh) / 2), $dw, $dh)
    $dv = New-Object System.Windows.Media.DrawingVisual
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($dv, [System.Windows.Media.BitmapScalingMode]::HighQuality)
    $dc = $dv.RenderOpen()
    $dc.DrawImage($Source, $rect)
    $dc.Close()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($Width, $Height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $ms = New-Object System.IO.MemoryStream
    try { $enc.Save($ms); return ,($ms.ToArray()) } finally { $ms.Dispose() }
}

function Get-ThemeBitmap([string]$ThemeDir, [string[]]$Names, [int]$Scale) {
    foreach ($n in $Names) {
        $p = Join-Path $ThemeDir ($n + '.icns')
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $info = Get-Item -LiteralPath $p
        $key = '{0}|{1}|{2}|{3}' -f $p, $Scale, $info.LastWriteTimeUtc.Ticks, $info.Length
        if ($script:ImgCache.ContainsKey($key)) { return $script:ImgCache[$key] }
        try {
            $png = Get-IcnsPng $p $Scale
            if ($png) {
                $bmp = ConvertTo-Bitmap $png
                $script:ImgCache[$key] = $bmp
                return $bmp
            }
        } catch { Write-Log "icns decode failed: $p" }
    }
    return $null
}

# Ecrit l'image de fond d'un theme (ic07 et ic13 a la resolution de l'ecran, comme les themes officiels).
function Set-ThemeBackground([string]$EfiOc, [string]$ThemeRel, [string]$ImagePath, [int]$Width, [int]$Height) {
    $src = Read-ImageFile $ImagePath
    $png = ConvertTo-PngBytes $src $Width $Height 'Cover'
    $icns = New-IcnsBytes $png $png
    return (Set-ThemeFile $EfiOc $ThemeRel 'Background.icns' $icns 'set-background')
}

function Set-ThemeIcon([string]$EfiOc, [string]$ThemeRel, [string]$IconName, [string]$ImagePath) {
    $src = Read-ImageFile $ImagePath
    $p1 = ConvertTo-PngBytes $src 128 128 'Contain'
    $p2 = ConvertTo-PngBytes $src 256 256 'Contain'
    return (Set-ThemeFile $EfiOc $ThemeRel ($IconName + '.icns') (New-IcnsBytes $p1 $p2) 'set-icon')
}

# ---------------------------------------------------------------------------------------------
#  Outils d'interface
# ---------------------------------------------------------------------------------------------
function New-Brush([string]$Hex) {
    $b = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Freeze()
    return $b
}

function Add-ComboItem($Combo, [string]$Text, $Value) {
    $it = New-Object System.Windows.Controls.ComboBoxItem
    $it.Content = $Text
    $it.Tag = $Value
    [void]$Combo.Items.Add($it)
}

function Select-ComboValue($Combo, $Value) {
    foreach ($it in $Combo.Items) {
        if ([string]$it.Tag -ceq [string]$Value) { $Combo.SelectedItem = $it; return $true }
    }
    $Combo.SelectedIndex = -1
    return $false
}

function Get-ComboValue($Combo) {
    if ($Combo.SelectedItem) { return $Combo.SelectedItem.Tag }
    return $null
}

function Set-TreeText($Element) {
    if ($Element -is [System.Windows.FrameworkElement]) {
        $tag = $Element.Tag
        if ($tag -is [string] -and $tag.StartsWith('t:')) {
            $txt = T $tag.Substring(2)
            if ($Element -is [System.Windows.Controls.TextBlock]) { $Element.Text = $txt }
            elseif ($Element -is [System.Windows.Controls.ContentControl]) { $Element.Content = $txt }
        }
    }
    if ($Element -is [System.Windows.DependencyObject]) {
        foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($Element)) {
            if ($c -is [System.Windows.DependencyObject]) { Set-TreeText $c }
        }
    }
}

function Set-Status([string]$Text) { $script:UI.txtStatus.Text = $Text }

function Get-PreviewSize {
    $v = [string](Get-ComboValue $script:UI.cmbPreviewRes)
    if ($v -match '^(\d+)x(\d+)$') { return @([int]$Matches[1], [int]$Matches[2]) }
    return @(1920, 1080)
}

function Get-EffectiveScale([int]$Width, [int]$Height) {
    $s = $null
    if ($script:Ctx) { $s = $script:Ctx.State['UIScale'] }
    if ($s -eq 2) { return 2 }
    if ($s -eq 1) { return 1 }
    # 0 / -1 : estimation du choix automatique d'OpenCore (ecrans de tres haute definition)
    if (($Width * $Height) -ge (2560 * 1600)) { return 2 }
    return 1
}

function Get-CurrentThemeRel {
    if (-not $script:Ctx) { return 'Acidanthera\GoldenGate' }
    return (Resolve-Variant ([string]$script:Ctx.State['PickerVariant']) ([string]$script:Ctx.State['BgColor']))
}

# ---------------------------------------------------------------------------------------------
#  Apercu
# ---------------------------------------------------------------------------------------------
function Add-PreviewImage($Bitmap, [double]$X, [double]$Y, [double]$W, [double]$H) {
    $img = New-Object System.Windows.Controls.Image
    $img.Source = $Bitmap
    $img.Width = $W; $img.Height = $H
    $img.Stretch = [System.Windows.Media.Stretch]::Fill
    [System.Windows.Controls.Canvas]::SetLeft($img, $X)
    [System.Windows.Controls.Canvas]::SetTop($img, $Y)
    [void]$script:UI.cnvPreview.Children.Add($img)
}

function Add-PreviewText([string]$Text, [double]$X, [double]$Y, [double]$W, [double]$Size, $Brush, [string]$Font, [string]$Align) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = $Size
    $tb.FontFamily = New-Object System.Windows.Media.FontFamily($Font)
    $tb.Foreground = $Brush
    if ($W -gt 0) { $tb.Width = $W }
    $tb.TextAlignment = $Align
    [System.Windows.Controls.Canvas]::SetLeft($tb, $X)
    [System.Windows.Controls.Canvas]::SetTop($tb, $Y)
    [void]$script:UI.cnvPreview.Children.Add($tb)
}

function Update-Preview {
    $cnv = $script:UI.cnvPreview
    $cnv.Children.Clear()
    $size = Get-PreviewSize
    $W = [double]$size[0]; $H = [double]$size[1]
    $cnv.Width = $W; $cnv.Height = $H
    if (-not $script:Ctx) { $cnv.Background = [System.Windows.Media.Brushes]::Black; return }
    $st = $script:Ctx.State
    $s = [double](Get-EffectiveScale ([int]$W) ([int]$H))
    $mode = [string]$st['PickerMode']
    $white = [System.Windows.Media.Brushes]::White

    $entries = @(
        @{ Label = 'macOS'; Icons = @('Apple', 'HardDrive') },
        @{ Label = 'Windows'; Icons = @('Windows', 'HardDrive') }
    )
    if ($st['HideAuxiliary'] -eq $false) {
        $entries += @{ Label = 'Recovery'; Icons = @('AppleRecv', 'Apple', 'HardDrive') }
        $entries += @{ Label = 'Reset NVRAM'; Icons = @('ResetNVRAM', 'Tool', 'HardDrive') }
    }

    if ($mode -eq 'Apple') {
        $cnv.Background = [System.Windows.Media.Brushes]::Black
        Add-PreviewText (T 'previewApple') 0 ($H / 2 - 20 * $s) $W (22 * $s) (New-Brush '#9AA5B1') 'Segoe UI' 'Center'
    }
    elseif ($mode -eq 'External' -and (Get-CanopyStatus $script:Ctx.EfiOc $script:Ctx.Plist.Doc).File) {
        $bgHex = [string]$st['BgColor']; if (-not $bgHex) { $bgHex = '#000000' }
        $cnv.Background = New-Brush $bgHex
        $c = [System.Windows.Media.ColorConverter]::ConvertFromString($bgHex)
        $lum = (0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B) / 255
        if ($lum -gt 0.55) { $labelBrush = [System.Windows.Media.Brushes]::Black } else { $labelBrush = $white }
        $themeDir = Get-ThemeDir $script:Ctx.EfiOc (Get-CurrentThemeRel)
        $sc = [int]$s

        $bg = Get-ThemeBitmap $themeDir @('Background') $sc
        if ($bg) {
            # OpenCanopy centre l'image sans la redimensionner
            Add-PreviewImage $bg (($W - $bg.PixelWidth) / 2) (($H - $bg.PixelHeight) / 2) $bg.PixelWidth $bg.PixelHeight
            $labelBrush = $white
        }

        $cell = 144 * $s; $gap = 8 * $s
        $n = $entries.Count
        $total = $n * $cell + ($n - 1) * $gap
        $x0 = ($W - $total) / 2
        $top = ($H - $cell) / 2 - 12 * $s
        for ($i = 0; $i -lt $n; $i++) {
            $x = $x0 + $i * ($cell + $gap)
            if ($i -eq 0) {
                $sel = Get-ThemeBitmap $themeDir @('Selected') $sc
                if ($sel) { Add-PreviewImage $sel $x $top $cell $cell }
            }
            $ico = Get-ThemeBitmap $themeDir $entries[$i].Icons $sc
            if ($ico) { Add-PreviewImage $ico ($x + 8 * $s) ($top + 8 * $s) (128 * $s) (128 * $s) }
            else {
                $r = New-Object System.Windows.Shapes.Rectangle
                $r.Width = 128 * $s; $r.Height = 128 * $s; $r.RadiusX = 20 * $s; $r.RadiusY = 20 * $s
                $r.Stroke = New-Brush '#7B8794'; $r.StrokeThickness = 2 * $s
                [System.Windows.Controls.Canvas]::SetLeft($r, $x + 8 * $s); [System.Windows.Controls.Canvas]::SetTop($r, $top + 8 * $s)
                [void]$cnv.Children.Add($r)
            }
            Add-PreviewText $entries[$i].Label ($x - $gap / 2) ($top + $cell + 4 * $s) ($cell + $gap) (12 * $s) $labelBrush 'Segoe UI' 'Center'
        }
        $selector = Get-ThemeBitmap $themeDir @('Selector') $sc
        if ($selector) {
            $sw = $selector.PixelWidth; $sh = $selector.PixelHeight
            Add-PreviewImage $selector ($x0 + ($cell - $sw) / 2) ($top + $cell + 30 * $s) $sw $sh
        }
        $attrs = [int64]0; if ($null -ne $st['PickerAttributes']) { $attrs = [int64]$st['PickerAttributes'] }
        if (($attrs -band 0x40) -eq 0) {
            $names = @('Restart', 'ShutDown')
            if (($attrs -band 0x100) -ne 0) { $names = @('ShutDown', 'Restart') }
            $bw = 36 * $s; $bgap = 36 * $s
            $bx = ($W - (2 * $bw + $bgap)) / 2
            $by = $H - $bw - 48 * $s
            for ($i = 0; $i -lt 2; $i++) {
                $b = Get-ThemeBitmap $themeDir @($names[$i]) $sc
                if ($b) { Add-PreviewImage $b ($bx + $i * ($bw + $bgap)) $by $bw $bw }
            }
        }
    }
    else {
        # Menu texte (Builtin, ou repli quand OpenCanopy est absent)
        $ca = [int64]0; if ($null -ne $st['ConsoleAttributes']) { $ca = [int64]$st['ConsoleAttributes'] }
        if ($ca -eq 0) { $ca = 7 }
        $fg = New-Brush $script:EfiColors[[int]($ca -band 0x0F)]
        $cnv.Background = New-Brush $script:EfiColors[[int](($ca -band 0x70) -shr 4)]
        $lines = @('OpenCore Boot Menu', '')
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $l = ' {0}. {1}' -f ($i + 1), $entries[$i].Label
            if ($i -eq 0) { $l += ' (dflt)' }
            $lines += $l
        }
        $lines += ''
        $lines += 'Choose the Operating System: '
        Add-PreviewText ($lines -join "`n") (8 * $s) (4 * $s) 0 (15 * $s) $fg 'Consolas' 'Left'
    }

    if ($st['ShowPicker'] -eq $false -and $mode -ne 'Apple') {
        $bar = New-Object System.Windows.Controls.Border
        $bar.Background = New-Brush '#CC1F2933'
        $bar.Width = $W; $bar.Padding = New-Object System.Windows.Thickness(0, (8 * $s), 0, (8 * $s))
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = (T 'previewHidden'); $t.Foreground = $white; $t.FontSize = 16 * $s; $t.TextAlignment = 'Center'
        $bar.Child = $t
        [System.Windows.Controls.Canvas]::SetLeft($bar, 0); [System.Windows.Controls.Canvas]::SetBottom($bar, 0)
        [void]$cnv.Children.Add($bar)
    }
}

# ---------------------------------------------------------------------------------------------
#  Remplissage des listes
# ---------------------------------------------------------------------------------------------
function Update-Combos {
    $u = $script:UI
    $u.cmbUIScale.Items.Clear()
    Add-ComboItem $u.cmbUIScale (T 'scaleKeep') -1
    Add-ComboItem $u.cmbUIScale (T 'scaleAuto') 0
    Add-ComboItem $u.cmbUIScale (T 'scale1') 1
    Add-ComboItem $u.cmbUIScale (T 'scale2') 2

    if ($u.cmbResolution.Items.Count -eq 0) {
        foreach ($r in @('Max', '1920x1080', '2560x1440', '3440x1440', '3840x2160')) { [void]$u.cmbResolution.Items.Add($r) }
    }
    if ($u.cmbTextRenderer.Items.Count -eq 0) {
        foreach ($r in @('BuiltinGraphics', 'BuiltinText', 'SystemGraphics', 'SystemText', 'SystemGeneric')) { Add-ComboItem $u.cmbTextRenderer $r $r }
    }
    $u.cmbConFg.Items.Clear(); $u.cmbConBg.Items.Clear()
    for ($i = 0; $i -lt 16; $i++) { Add-ComboItem $u.cmbConFg (T ('col' + $i)) $i }
    for ($i = 0; $i -lt 8; $i++)  { Add-ComboItem $u.cmbConBg (T ('col' + $i)) $i }

    if ($u.cmbPreviewRes.Items.Count -eq 0) {
        foreach ($r in @('1920x1080', '2560x1440', '3840x2160')) { Add-ComboItem $u.cmbPreviewRes ($r.Replace('x', ' × ')) $r }
        $u.cmbPreviewRes.SelectedIndex = 0
    }
    if ($u.cmbBgRes.Items.Count -eq 0) {
        foreach ($r in @('1920x1080', '2560x1440', '3440x1440', '3840x2160')) { Add-ComboItem $u.cmbBgRes ($r.Replace('x', ' × ')) $r }
        $u.cmbBgRes.SelectedIndex = 0
    }

    $u.cmbVariant.Items.Clear()
    Add-ComboItem $u.cmbVariant (T 'variantAuto') 'Auto'
    Add-ComboItem $u.cmbVariant (T 'variantDefault') 'Default'
    if ($script:Ctx) {
        $themes = @(Get-Themes $script:Ctx.EfiOc)
        foreach ($t in $themes) { Add-ComboItem $u.cmbVariant $t $t }
        $cur = [string]$script:Ctx.State['PickerVariant']
        if ($cur -and $cur -ne 'Auto' -and $cur -ne 'Default' -and ($themes -notcontains $cur.Replace('/', '\'))) {
            Add-ComboItem $u.cmbVariant ($cur + '  (?)') $cur
        }
    }

    # cases a cocher de PickerAttributes
    $u.pnlAttrs.Children.Clear()
    $script:AttrChecks = @()
    foreach ($bit in $script:AttrBits) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = (T ('attr' + $bit)); $tb.TextWrapping = 'Wrap'
        $cb.Content = $tb
        $cb.Tag = $bit
        $cb.Add_Click($script:OnChange)
        [void]$u.pnlAttrs.Children.Add($cb)
        $script:AttrChecks += $cb
    }

    Update-CatalogFilters
    $u.colDate.Header = (T 'colDate'); $u.colType.Header = (T 'colType'); $u.colReason.Header = (T 'colReason')
    $u.colFiles.Header = (T 'colFiles'); $u.colSize.Header = (T 'colSize')
    $u.txtBackupInfo.Text = (T 'backupsInfo' $script:BackupRoot)
}

function Update-Swatches {
    $p = $script:UI.pnlSwatches
    if ($p.Children.Count -gt 0) { return }
    foreach ($hex in @('#000000', '#BFBFBF', '#1C1C1E', '#0B1F3A', '#12372A', '#3B0D2E', '#2B2D42', '#4A1D1D', '#F2F2F7')) {
        $b = New-Object System.Windows.Controls.Button
        $b.Width = 26; $b.Height = 26; $b.Margin = '0,0,6,0'; $b.Cursor = 'Hand'
        $b.Background = New-Brush $hex; $b.BorderBrush = New-Brush '#CBD2D9'; $b.ToolTip = $hex
        $b.Tag = $hex
        $b.Add_Click({ param($s, $e) Invoke-Safe { Set-BgColor ([string]$s.Tag) } })
        [void]$p.Children.Add($b)
    }
}

function Update-IconTiles {
    $p = $script:UI.pnlIcons
    $p.Children.Clear()
    if (-not $script:Ctx) { return }
    $themeDir = Get-ThemeDir $script:Ctx.EfiOc (Get-CurrentThemeRel)
    $names = @($script:IconSlots)
    if (Test-Path -LiteralPath $themeDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $themeDir -Filter '*.icns' -File | Sort-Object Name)) {
            $bn = $f.BaseName
            if ($names -notcontains $bn -and $script:SystemIcons -notcontains $bn) { $names += $bn }
        }
    }
    foreach ($n in $names) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $script:Win.FindResource('Tile')
        $btn.Tag = $n
        $btn.ToolTip = $n + '.icns'
        $sp = New-Object System.Windows.Controls.StackPanel
        $bmp = Get-ThemeBitmap $themeDir @($n) 1
        if ($bmp) {
            $img = New-Object System.Windows.Controls.Image
            $img.Source = $bmp; $img.Width = 52; $img.Height = 52
            [void]$sp.Children.Add($img)
        } else {
            $ph = New-Object System.Windows.Controls.TextBlock
            $ph.Text = '+'; $ph.FontSize = 30; $ph.Height = 52; $ph.TextAlignment = 'Center'; $ph.Foreground = New-Brush '#9AA5B1'
            [void]$sp.Children.Add($ph)
        }
        $lb = New-Object System.Windows.Controls.TextBlock
        $lb.Text = $n; $lb.FontSize = 11; $lb.TextAlignment = 'Center'; $lb.TextTrimming = 'CharacterEllipsis'; $lb.Width = 74
        [void]$sp.Children.Add($lb)
        $btn.Content = $sp
        $btn.Add_Click({ param($s, $e) Invoke-Safe { Invoke-ReplaceIcon ([string]$s.Tag) } })
        [void]$p.Children.Add($btn)
    }
}

function Update-BackupList {
    $table = New-Object System.Data.DataTable
    foreach ($c in @('Id', 'Date', 'Type', 'Reason', 'Files', 'Size')) { [void]$table.Columns.Add($c) }
    foreach ($b in (Get-Backups)) {
        $date = $b.Created
        try { $date = ([datetime]$b.Created).ToString('yyyy-MM-dd HH:mm:ss') } catch { }
        if ($b.Kind -eq 'full') { $kind = (T 'kindFull'); $files = '*' } else { $kind = (T 'kindAuto'); $files = [string](@($b.Files).Count + @($b.Absent).Count) }
        $reason = T ('r_' + $b.Reason)
        if ($reason -eq ('r_' + $b.Reason)) { $reason = $b.Reason }
        [void]$table.Rows.Add($b.Id, $date, $kind, $reason, $files, (Format-Size $b.Size))
    }
    $script:UI.lvBackups.ItemsSource = $table.DefaultView
}

# ---------------------------------------------------------------------------------------------
#  Etat <-> interface
# ---------------------------------------------------------------------------------------------
function Set-FieldEnabled($Control, [string]$Id) {
    $present = ($script:Ctx -and ($null -ne $script:Ctx.Orig[$Id]))
    $Control.IsEnabled = [bool]$present
    if (-not $present) { $Control.ToolTip = (T 'notInConfig') } else { $Control.ToolTip = $null }
}

function Sync-UiFromState {
    $script:Loading = $true
    try {
        $u = $script:UI
        $has = [bool]$script:Ctx
        foreach ($n in @('btnSave', 'btnRevert', 'btnReload', 'btnDupTheme', 'btnImportTheme', 'btnOpenTheme', 'btnBgSet', 'btnBgRemove',
                'btnBgApply', 'btnBgBlack', 'btnBgGray', 'btnBackupFull', 'btnCanopyInstall', 'txtBgHex')) { $u[$n].IsEnabled = $has }
        if (-not $has) {
            $u.txtEfi.Text = ''
            Set-Status (T 'stNoEfi')
            Update-Preview
            return
        }
        $st = $script:Ctx.State
        $u.txtEfi.Text = $script:Ctx.EfiOc

        $mode = [string]$st['PickerMode']
        $u.rbBuiltin.IsChecked  = ($mode -eq 'Builtin')
        $u.rbExternal.IsChecked = ($mode -eq 'External')
        $u.rbApple.IsChecked    = ($mode -eq 'Apple')
        foreach ($rb in @($u.rbBuiltin, $u.rbExternal, $u.rbApple)) { Set-FieldEnabled $rb 'PickerMode' }

        [void](Select-ComboValue $u.cmbUIScale $st['UIScale']);          Set-FieldEnabled $u.cmbUIScale 'UIScale'
        $u.cmbResolution.Text = [string]$st['Resolution'];              Set-FieldEnabled $u.cmbResolution 'Resolution'
        [void](Select-ComboValue $u.cmbTextRenderer $st['TextRenderer']); Set-FieldEnabled $u.cmbTextRenderer 'TextRenderer'

        $ca = [int64]0; if ($null -ne $st['ConsoleAttributes']) { $ca = [int64]$st['ConsoleAttributes'] }
        if ($ca -eq 0) { $ca = 7 }
        [void](Select-ComboValue $u.cmbConFg ([int]($ca -band 0x0F)));          Set-FieldEnabled $u.cmbConFg 'ConsoleAttributes'
        [void](Select-ComboValue $u.cmbConBg ([int](($ca -band 0x70) -shr 4))); Set-FieldEnabled $u.cmbConBg 'ConsoleAttributes'

        $attrs = [int64]0; if ($null -ne $st['PickerAttributes']) { $attrs = [int64]$st['PickerAttributes'] }
        foreach ($cb in $script:AttrChecks) {
            $cb.IsChecked = (($attrs -band [int64]$cb.Tag) -ne 0)
            Set-FieldEnabled $cb 'PickerAttributes'
        }

        [void](Select-ComboValue $u.cmbVariant ([string]$st['PickerVariant'])); Set-FieldEnabled $u.cmbVariant 'PickerVariant'

        $pairs = @(
            @('chkShowPicker', 'ShowPicker'), @('chkHideAux', 'HideAuxiliary'), @('chkHotKeys', 'PollAppleHotKeys'),
            @('chkAllowDefault', 'AllowSetDefault'), @('chkAudioAssist', 'PickerAudioAssist'), @('chkHibSkip', 'HibernateSkipsPicker'),
            @('chkVerbose', 'Verbose')
        )
        foreach ($p in $pairs) {
            $u[$p[0]].IsChecked = ($st[$p[1]] -eq $true)
            Set-FieldEnabled $u[$p[0]] $p[1]
        }
        $u.txtTimeout.Text = [string]$st['Timeout'];      Set-FieldEnabled $u.txtTimeout 'Timeout'
        $u.txtTakeoff.Text = [string]$st['TakeoffDelay']; Set-FieldEnabled $u.txtTakeoff 'TakeoffDelay'

        $bg = [string]$st['BgColor']
        $u.txtBgHex.Text = $bg
        if ($bg) { $u.bdSwatch.Background = New-Brush $bg } else { $u.bdSwatch.Background = [System.Windows.Media.Brushes]::Transparent }
    } finally { $script:Loading = $false }
    Update-Derived
}

function Read-IntBox($TextBox, $Fallback, [int64]$Min, [int64]$Max) {
    $v = 0L
    if ([int64]::TryParse($TextBox.Text.Trim(), [ref]$v) -and $v -ge $Min -and $v -le $Max) { return $v }
    return $Fallback
}

function Update-StateFromUi {
    if (-not $script:Ctx) { return }
    $u = $script:UI; $st = $script:Ctx.State; $orig = $script:Ctx.Orig

    if ($null -ne $orig['PickerMode']) {
        if ($u.rbExternal.IsChecked) { $st['PickerMode'] = 'External' }
        elseif ($u.rbApple.IsChecked) { $st['PickerMode'] = 'Apple' }
        elseif ($u.rbBuiltin.IsChecked) { $st['PickerMode'] = 'Builtin' }
    }
    if ($null -ne $orig['UIScale']) { $v = Get-ComboValue $u.cmbUIScale; if ($null -ne $v) { $st['UIScale'] = [int64]$v } }
    if ($null -ne $orig['Resolution']) {
        $r = $u.cmbResolution.Text.Trim()
        if ($r -match '^(Max|\d+x\d+(@\d+)?)$') { $st['Resolution'] = $r }
    }
    if ($null -ne $orig['TextRenderer']) { $v = Get-ComboValue $u.cmbTextRenderer; if ($v) { $st['TextRenderer'] = [string]$v } }
    if ($null -ne $orig['ConsoleAttributes']) {
        $fg = Get-ComboValue $u.cmbConFg; $bgc = Get-ComboValue $u.cmbConBg
        if ($null -ne $fg -and $null -ne $bgc) {
            $val = [int64]$fg + ([int64]$bgc * 16)
            # 7 (gris clair sur noir) est la valeur par defaut : on conserve 0 si c'etait deja le cas
            if ($val -eq 7 -and [int64]$orig['ConsoleAttributes'] -eq 0) { $val = 0 }
            $st['ConsoleAttributes'] = $val
        }
    }
    if ($null -ne $orig['PickerAttributes']) {
        $known = [int64]0; $set = [int64]0
        foreach ($cb in $script:AttrChecks) {
            $known = $known -bor [int64]$cb.Tag
            if ($cb.IsChecked) { $set = $set -bor [int64]$cb.Tag }
        }
        $st['PickerAttributes'] = (([int64]$orig['PickerAttributes']) -band (-bnot $known)) -bor $set
    }
    if ($null -ne $orig['PickerVariant']) { $v = Get-ComboValue $u.cmbVariant; if ($v) { $st['PickerVariant'] = [string]$v } }

    $pairs = @(
        @('chkShowPicker', 'ShowPicker'), @('chkHideAux', 'HideAuxiliary'), @('chkHotKeys', 'PollAppleHotKeys'),
        @('chkAllowDefault', 'AllowSetDefault'), @('chkAudioAssist', 'PickerAudioAssist'), @('chkHibSkip', 'HibernateSkipsPicker'),
        @('chkVerbose', 'Verbose')
    )
    foreach ($p in $pairs) { if ($null -ne $orig[$p[1]]) { $st[$p[1]] = [bool]$u[$p[0]].IsChecked } }
    if ($null -ne $orig['Timeout'])      { $st['Timeout']      = Read-IntBox $u.txtTimeout $st['Timeout'] 0 65535 }
    if ($null -ne $orig['TakeoffDelay']) { $st['TakeoffDelay'] = Read-IntBox $u.txtTakeoff $st['TakeoffDelay'] 0 10000000 }
}

# Elements calcules : etat OpenCanopy, theme utilise, apercu, barre d'etat.
function Update-Derived {
    if (-not $script:Ctx) { return }
    $u = $script:UI; $st = $script:Ctx.State
    $can = Get-CanopyStatus $script:Ctx.EfiOc $script:Ctx.Plist.Doc
    if (-not $can.File) { $msg = (T 'canopyMissing'); $ok = $false }
    elseif (-not $can.Resources) { $msg = (T 'canopyNoRes'); $ok = $false }
    elseif (-not $can.Enabled) { $msg = (T 'canopyWillDeclare'); $ok = $true }
    else { $msg = (T 'canopyOk'); $ok = $true }
    $u.txtCanopy.Text = $msg
    if ($ok) { $u.bdCanopy.Background = New-Brush '#F0FDFA'; $u.bdCanopy.BorderBrush = New-Brush '#99D5CC' }
    else     { $u.bdCanopy.Background = New-Brush '#FFF7E6'; $u.bdCanopy.BorderBrush = New-Brush '#F0C36D' }
    if ($st['PickerMode'] -eq 'External' -or -not $can.File) { $u.bdCanopy.Visibility = 'Visible' } else { $u.bdCanopy.Visibility = 'Collapsed' }

    $themeRel = Get-CurrentThemeRel
    $themeDir = Get-ThemeDir $script:Ctx.EfiOc $themeRel
    $exists = Test-Path -LiteralPath $themeDir
    if ($exists) { $u.txtEffTheme.Text = (T 'effTheme' $themeRel) } else { $u.txtEffTheme.Text = (T 'effThemeMissing' $themeRel) }
    foreach ($n in @('btnDupTheme', 'btnOpenTheme', 'btnBgSet')) { $u[$n].IsEnabled = $exists }
    $bgFile = Join-Path $themeDir 'Background.icns'
    $hasBg = Test-Path -LiteralPath $bgFile -PathType Leaf
    $u.btnBgRemove.IsEnabled = $hasBg
    if ($hasBg) {
        $sz = $null
        try { $sz = Get-PngSize (Get-IcnsPng $bgFile 1) } catch { }
        if ($sz) { $u.txtBgInfo.Text = (T 'bgInfo' $sz.Width $sz.Height) } else { $u.txtBgInfo.Text = 'Background.icns' }
    } else { $u.txtBgInfo.Text = (T 'bgNone') }

    if ($script:LastTilesTheme -ne ($themeRel + '|' + $script:TilesStamp)) {
        Update-IconTiles
        $script:LastTilesTheme = ($themeRel + '|' + $script:TilesStamp)
    }
    Update-Preview

    $changes = @(Get-StateChanges $script:Ctx.Orig $st)
    $free = Get-FreeSpace $script:Ctx.EfiOc
    $tail = ''
    if ($free -ge 0) { $tail = '   ·   ' + (T 'stFree' (Format-Size $free)) }
    if ($changes.Count -gt 0) { Set-Status ((T 'stModified' ($changes -join ', ')) + $tail) }
    elseif ($script:StatusNote) { Set-Status ($script:StatusNote + $tail) }
    else { Set-Status ((T 'stLoaded' $script:Ctx.Plist.Path) + $tail) }
    $u.btnSave.IsEnabled = ($changes.Count -gt 0)
    $u.btnRevert.IsEnabled = ($changes.Count -gt 0)
}

$script:TilesStamp = 0
$script:LastTilesTheme = ''
$script:StatusNote = $null
$script:ForceClose = $false

$script:OnChange = {
    if ($script:Loading) { return }
    Invoke-Safe {
        $script:StatusNote = $null
        Update-StateFromUi
        Update-Derived
    }
}

# ---------------------------------------------------------------------------------------------
#  Actions
# ---------------------------------------------------------------------------------------------
function Open-Efi([string]$Path) {
    $cfg = Join-Path $Path 'config.plist'
    if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) { throw (T 'msgNoEfi') }
    $plist = Read-PlistFile $cfg
    $state = Read-State $plist
    $script:Ctx = @{ EfiOc = $Path.TrimEnd('\'); Plist = $plist; Orig = (Copy-State $state); State = $state }
    $script:ImgCache = @{}
    $script:TilesStamp++
    $script:StatusNote = $null
    if (-not $plist.Lossless) { $script:StatusNote = (T 'stReformat') }
    $script:Settings.LastEfi = $script:Ctx.EfiOc
    Save-Settings $script:Settings
    $script:Loading = $true
    try { Update-Combos } finally { $script:Loading = $false }
    Sync-UiFromState
    Update-BackupList
    Write-Log "Opened $cfg (lossless=$($plist.Lossless), crlf=$($plist.Crlf))"
}

function Test-CanDiscard {
    if (-not $script:Ctx) { return $true }
    if (@(Get-StateChanges $script:Ctx.Orig $script:Ctx.State).Count -eq 0) { return $true }
    return (Show-Confirm (T 'msgUnsaved'))
}

function Invoke-Browse {
    if (-not (Test-CanDiscard)) { return }
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = (T 'msgPickEfi')
    $dlg.ShowNewFolderButton = $false
    if ($script:Ctx) { $dlg.SelectedPath = $script:Ctx.EfiOc }
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $p = $dlg.SelectedPath
    # tolere la selection de la racine ou du dossier EFI
    foreach ($cand in @($p, (Join-Path $p 'OC'), (Join-Path $p 'EFI\OC'))) {
        if (Test-Path -LiteralPath (Join-Path $cand 'config.plist')) { Open-Efi $cand; return }
    }
    throw (T 'msgNoEfi')
}

function Invoke-Save {
    if (-not $script:Ctx) { return }
    Update-StateFromUi
    try {
        $res = Save-Config $script:Ctx.Plist $script:Ctx.Orig $script:Ctx.State $script:Ctx.EfiOc
    } catch {
        if ($_.Exception.Message -eq 'OCD_CHANGED_ON_DISK') {
            if (Show-Confirm (T 'msgChanged')) { Open-Efi $script:Ctx.EfiOc }
            return
        }
        # le document en memoire a pu etre modifie : on repart du fichier
        $failed = $_
        try { Open-Efi $script:Ctx.EfiOc } catch { }
        throw $failed
    }
    $changed = @(Get-StateChanges $script:Ctx.Orig $script:Ctx.State)
    $notes = @($res.Notes)
    Open-Efi $script:Ctx.EfiOc
    $script:StatusNote = (T 'stSaved' $res.BackupId)
    Update-Derived
    $msgs = @()
    if ($notes -contains 'canopy-driver') { $msgs += (T 'msgCanopyAdded') }
    if ($changed -contains 'BgColor' -or $changed -contains 'Verbose' -or $changed -contains 'UIScale') { $msgs += (T 'msgNvram') }
    if ($msgs.Count -gt 0) { Show-Info ($msgs -join "`n`n") }
}

function Set-BgColor([string]$Hex) {
    if (-not $script:Ctx) { return }
    if ($Hex -notmatch '^#?[0-9A-Fa-f]{6}$') { throw (T 'msgBadColor') }
    if (-not $Hex.StartsWith('#')) { $Hex = '#' + $Hex }
    $script:Ctx.State['BgColor'] = $Hex.ToUpper()
    $script:StatusNote = $null
    $script:UI.txtBgHex.Text = $Hex.ToUpper()
    $script:UI.bdSwatch.Background = New-Brush $Hex
    Update-Derived
}

function Select-Theme([string]$ThemeRel) {
    $script:Loading = $true
    try { Update-Combos } finally { $script:Loading = $false }
    if ($null -ne $script:Ctx.Orig['PickerVariant']) { $script:Ctx.State['PickerVariant'] = $ThemeRel }
    Sync-UiFromState
}

function Invoke-DuplicateTheme {
    $src = Get-CurrentThemeRel
    $default = ($src.Split('\')[-1]) + '-Custom'
    $name = Show-InputBox (T 'dupTheme') (T 'msgThemeName') $default
    if (-not $name) { return }
    $new = Copy-ThemeFolder $script:Ctx.EfiOc (Get-ThemeDir $script:Ctx.EfiOc $src) $name 'duplicate-theme'
    Select-Theme $new
    Update-BackupList
    Show-Info (T 'msgThemeCreated' $new)
}

function Invoke-ImportTheme {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.ShowNewFolderButton = $false
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $srcDir = $dlg.SelectedPath
    $default = ((Split-Path -Leaf $srcDir) -replace '[^A-Za-z0-9_\-]', '')
    if (-not $default) { $default = 'MyTheme' }
    $name = Show-InputBox (T 'importTheme') (T 'msgThemeName') $default
    if (-not $name) { return }
    $new = Copy-ThemeFolder $script:Ctx.EfiOc $srcDir $name 'import-theme'
    Select-Theme $new
    Update-BackupList
    Show-Info (T 'msgThemeCreated' $new)
}

function Invoke-SetBackground {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = (T 'msgImgFilter')
    if (-not $dlg.ShowDialog($script:Win)) { return }
    $res = [string](Get-ComboValue $script:UI.cmbBgRes)
    if ($res -notmatch '^(\d+)x(\d+)$') { return }
    $w = [int]$Matches[1]; $h = [int]$Matches[2]
    $script:Win.Cursor = [System.Windows.Input.Cursors]::Wait
    try { [void](Set-ThemeBackground $script:Ctx.EfiOc (Get-CurrentThemeRel) $dlg.FileName $w $h) }
    finally { $script:Win.Cursor = $null }
    $script:TilesStamp++
    Update-Derived
    Update-BackupList
}

function Invoke-RemoveBackground {
    $theme = Get-CurrentThemeRel
    if (-not (Show-Confirm (T 'msgRemoveBg' $theme))) { return }
    [void](Remove-ThemeFile $script:Ctx.EfiOc $theme 'Background.icns' 'remove-background')
    Update-Derived
    Update-BackupList
}

function Invoke-ReplaceIcon([string]$IconName) {
    if (-not $script:Ctx) { return }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = (T 'msgPngFilter')
    $dlg.Title = $IconName + '.icns'
    if (-not $dlg.ShowDialog($script:Win)) { return }
    [void](Set-ThemeIcon $script:Ctx.EfiOc (Get-CurrentThemeRel) $IconName $dlg.FileName)
    $script:TilesStamp++
    Update-Derived
    Update-BackupList
}

function Invoke-InstallCanopy {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'OpenCanopy.efi|OpenCanopy.efi'
    $dlg.Title = (T 'canopyPick')
    if (-not $dlg.ShowDialog($script:Win)) { return }
    Install-CanopyFile $script:Ctx.EfiOc $dlg.FileName
    Update-Derived
    Update-BackupList
    Show-Info (T 'canopyInstalled')
}

function Get-SelectedBackupId {
    $it = $script:UI.lvBackups.SelectedItem
    if (-not $it) { return $null }
    return [string]$it['Id']
}

function Invoke-Restore {
    $id = Get-SelectedBackupId
    if (-not $id -or -not $script:Ctx) { return }
    $b = @(Get-Backups | Where-Object { $_.Id -eq $id })[0]
    $msg = (T 'msgRestore' $script:Ctx.EfiOc)
    if ($b.EfiOc -and ($b.EfiOc.TrimEnd('\') -ine $script:Ctx.EfiOc)) { $msg = (T 'msgRestoreOther' $b.EfiOc) + "`n`n" + $msg }
    if (-not (Show-Confirm $msg)) { return }
    $script:Win.Cursor = [System.Windows.Input.Cursors]::Wait
    try { [void](Restore-Backup $id $script:Ctx.EfiOc) } finally { $script:Win.Cursor = $null }
    Open-Efi $script:Ctx.EfiOc
    $script:StatusNote = (T 'stRestored')
    Update-Derived
}

function Invoke-FullBackup {
    if (-not $script:Ctx) { return }
    $script:Win.Cursor = [System.Windows.Input.Cursors]::Wait
    try { $id = New-FullBackup $script:Ctx.EfiOc 'manual' } finally { $script:Win.Cursor = $null }
    Update-BackupList
    $script:StatusNote = (T 'stBackupDone' $id)
    Update-Derived
}

function Set-Language([string]$Lang) {
    if (-not $script:Strings.ContainsKey($Lang)) { $Lang = 'en' }
    $script:Lang = $Lang
    $script:Settings.Lang = $Lang
    Save-Settings $script:Settings
    $script:Win.Title = $script:AppName + ' ' + $script:AppVer
    Set-TreeText $script:Win
    $script:Loading = $true
    try { Update-Combos } finally { $script:Loading = $false }
    $script:TilesStamp++
    Sync-UiFromState
    Update-BackupList
}

function Show-Page([int]$Index) {
    $pages = @($script:UI.pageStyle, $script:UI.pageTheme, $script:UI.pageCatalog, $script:UI.pageOptions, $script:UI.pageBackups)
    for ($i = 0; $i -lt $pages.Count; $i++) {
        if ($i -eq $Index) { $pages[$i].Visibility = 'Visible' } else { $pages[$i].Visibility = 'Collapsed' }
    }
    if ($Index -eq 2) { Update-CatalogList }
    if ($Index -eq 4) { Update-BackupList }
}

# ---------------------------------------------------------------------------------------------
#  Catalogue en ligne (interface)
# ---------------------------------------------------------------------------------------------
function Invoke-UiPump {
    $script:Win.Dispatcher.Invoke([Action] { }, [System.Windows.Threading.DispatcherPriority]::Background)
}

function Update-CatalogFilters {
    $u = $script:UI
    $cat = Get-Catalog
    $curSource = [string](Get-ComboValue $u.cmbCatSource)
    $curGroup  = [string](Get-ComboValue $u.cmbCatGroup)
    $u.cmbCatSource.Items.Clear()
    Add-ComboItem $u.cmbCatSource (T 'catAll') ''
    foreach ($id in ($cat.Sources.Keys | Sort-Object)) { Add-ComboItem $u.cmbCatSource ([string]$cat.Sources[$id].Name) $id }
    if (-not (Select-ComboValue $u.cmbCatSource $curSource)) { $u.cmbCatSource.SelectedIndex = 0 }
    Update-CatalogGroups $curGroup
    Update-CatalogList
}

function Update-CatalogGroups([string]$Keep) {
    $u = $script:UI
    $source = [string](Get-ComboValue $u.cmbCatSource)
    $groups = @()
    foreach ($t in (Get-Catalog).Themes) {
        if ($source -and $t.Source -ne $source) { continue }
        if ($groups -notcontains $t.Group) { $groups += $t.Group }
    }
    $u.cmbCatGroup.Items.Clear()
    Add-ComboItem $u.cmbCatGroup (T 'catAllGroups') ''
    foreach ($g in $groups) { Add-ComboItem $u.cmbCatGroup $g $g }
    if (-not (Select-ComboValue $u.cmbCatGroup $Keep)) { $u.cmbCatGroup.SelectedIndex = 0 }
}

function Get-SelectedCatalogTheme {
    $it = $script:UI.lstCatalog.SelectedItem
    if (-not $it) { return $null }
    return (Get-CatalogTheme ([string]$it.Tag))
}

function Update-CatalogList {
    $u = $script:UI
    $keep = $null
    if ($u.lstCatalog.SelectedItem) { $keep = [string]$u.lstCatalog.SelectedItem.Tag }
    $source = [string](Get-ComboValue $u.cmbCatSource)
    $group  = [string](Get-ComboValue $u.cmbCatGroup)
    $was = $script:Loading
    $script:Loading = $true
    try {
        $u.lstCatalog.Items.Clear()
        foreach ($t in (Get-Catalog).Themes) {
            if ($source -and $t.Source -ne $source) { continue }
            if ($group -and $t.Group -ne $group) { continue }
            $text = $t.Group + '  ·  ' + $t.Name
            if ($t.Note) { $text += '  (' + $t.Note + ')' }
            $installed = $false
            if ($script:Ctx) { $installed = Test-Path -LiteralPath (Get-ThemeDir $script:Ctx.EfiOc (Get-CatalogThemeRel $t)) }
            $item = New-Object System.Windows.Controls.ListBoxItem
            if ($installed) { $text += '   ✓ ' + (T 'catInstalled'); $item.FontWeight = 'SemiBold' }
            $item.Content = $text
            $item.Tag = $t.Id
            $item.Padding = '6,4'
            [void]$u.lstCatalog.Items.Add($item)
            if ($keep -and $t.Id -ceq $keep) { $u.lstCatalog.SelectedItem = $item }
        }
    } finally { $script:Loading = $was }
    Update-CatalogInfo
}

function Update-CatalogInfo {
    $u = $script:UI
    $t = Get-SelectedCatalogTheme
    $has = ($t -and $script:Ctx -and -not $script:CatalogBusy)
    $u.btnCatApply.IsEnabled = [bool]$has
    $u.btnCatInstall.IsEnabled = [bool]$has
    $u.btnCatPreview.IsEnabled = [bool]($t -and $t.Preview -and -not $script:CatalogBusy)
    $u.btnCatSource.IsEnabled = [bool]$t
    if (-not $t) { $u.txtCatInfo.Text = (T 'catNoSel'); return }
    $src = (Get-Catalog).Sources[$t.Source]
    $u.txtCatInfo.Text = (T 'catInfo' (Get-CatalogThemeRel $t) $t.Files.Count ([string]$src.Repo) ([string]$src.Commit).Substring(0, 7))
}

function Set-CatalogBusy([bool]$Busy) {
    $script:CatalogBusy = $Busy
    $u = $script:UI
    foreach ($n in @('lstCatalog', 'lstNav', 'cmbCatSource', 'cmbCatGroup', 'btnBrowse', 'btnReload')) { $u[$n].IsEnabled = (-not $Busy) }
    if ($Busy) {
        $u.btnSave.IsEnabled = $false; $u.btnRevert.IsEnabled = $false
        $script:Win.Cursor = [System.Windows.Input.Cursors]::Wait
    } else {
        $script:Win.Cursor = $null
        $u.pbCat.Value = 0
    }
    Update-CatalogInfo
}

function Get-BgResolution {
    $res = [string](Get-ComboValue $script:UI.cmbBgRes)
    if ($res -match '^(\d+)x(\d+)$') { return @([int]$Matches[1], [int]$Matches[2]) }
    return @(1920, 1080)
}

function Invoke-CatalogInstall([bool]$Apply) {
    $t = Get-SelectedCatalogTheme
    if (-not $t -or -not $script:Ctx -or $script:CatalogBusy) { return }
    $res = Get-BgResolution
    $u = $script:UI
    Update-StateFromUi
    Set-CatalogBusy $true
    try {
        $r = Install-CatalogTheme $script:Ctx.EfiOc $t ([bool]$u.chkCatBg.IsChecked) $res[0] $res[1] {
            param($i, $n, $name)
            $script:UI.pbCat.Maximum = $n
            $script:UI.pbCat.Value = $i
            $script:UI.txtCatStatus.Text = (T 'catDownloading' $i $n $name)
            Invoke-UiPump
        }
    } finally { Set-CatalogBusy $false }
    $script:ImgCache = @{}
    $script:TilesStamp++
    $msg = (T 'catDone' $r.ThemeRel $r.Count (Format-Size $r.Bytes))
    if (@($r.Completed).Count -gt 0) { $msg += (T 'catCompleted' (@($r.Completed) -join ', ')) }
    $u.txtCatStatus.Text = $msg
    Write-Log $msg
    if ($Apply) {
        if ($null -ne $script:Ctx.Orig['PickerMode']) { $script:Ctx.State['PickerMode'] = 'External' }
        Select-Theme $r.ThemeRel
        Update-CatalogList
        Update-BackupList
        if (Show-Confirm (T 'catApplyNow' $r.ThemeRel)) { Invoke-Save }
    } else {
        $script:Loading = $true
        try { Update-Combos } finally { $script:Loading = $false }
        Sync-UiFromState
        Update-CatalogList
        Update-BackupList
    }
}

function Show-CatalogPreview {
    $t = Get-SelectedCatalogTheme
    if (-not $t -or -not $t.Preview) { return }
    $script:Win.Cursor = [System.Windows.Input.Cursors]::Wait
    try { $bmp = ConvertTo-Bitmap (Get-CatalogFile $t $t.Preview $false 16MB) }
    finally { $script:Win.Cursor = $null }
    $w = New-Object System.Windows.Window
    $w.Title = $t.Group + ' · ' + $t.Name
    $w.Width = 980; $w.Height = 760; $w.Owner = $script:Win; $w.WindowStartupLocation = 'CenterOwner'
    $w.Background = New-Brush '#1B1D21'
    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'; $sv.HorizontalScrollBarVisibility = 'Disabled'
    $img = New-Object System.Windows.Controls.Image
    $img.Source = $bmp
    $img.Stretch = [System.Windows.Media.Stretch]::Uniform
    $sv.Content = $img
    $w.Content = $sv
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------------------------------------
#  Evenements
# ---------------------------------------------------------------------------------------------
$script:CatalogBusy = $false
$u = $script:UI
foreach ($c in @($u.rbBuiltin, $u.rbExternal, $u.rbApple, $u.chkShowPicker, $u.chkHideAux, $u.chkHotKeys, $u.chkAllowDefault,
        $u.chkAudioAssist, $u.chkHibSkip, $u.chkVerbose)) { $c.Add_Click($script:OnChange) }
foreach ($c in @($u.cmbUIScale, $u.cmbTextRenderer, $u.cmbConFg, $u.cmbConBg, $u.cmbVariant, $u.cmbResolution)) { $c.Add_SelectionChanged($script:OnChange) }
foreach ($c in @($u.txtTimeout, $u.txtTakeoff, $u.cmbResolution)) { $c.Add_LostFocus($script:OnChange) }
$u.txtTimeout.Add_TextChanged($script:OnChange)

$u.cmbPreviewRes.Add_SelectionChanged({ if (-not $script:Loading) { Invoke-Safe { Update-Preview } } })
$u.lstNav.Add_SelectionChanged({ Invoke-Safe { Show-Page $script:UI.lstNav.SelectedIndex } })
$u.cmbLang.Add_SelectionChanged({
    if ($script:Loading) { return }
    Invoke-Safe { $v = Get-ComboValue $script:UI.cmbLang; if ($v) { Update-StateFromUi; Set-Language ([string]$v) } }
})

$u.btnBrowse.Add_Click({ Invoke-Safe { Invoke-Browse } })
$u.btnReload.Add_Click({ Invoke-Safe { if ($script:Ctx -and (Test-CanDiscard)) { Open-Efi $script:Ctx.EfiOc } } })
$u.btnRevert.Add_Click({ Invoke-Safe { if ($script:Ctx) { $script:Ctx.State = Copy-State $script:Ctx.Orig; Sync-UiFromState } } })
$u.btnSave.Add_Click({ Invoke-Safe { Invoke-Save } })

$u.btnCanopyInstall.Add_Click({ Invoke-Safe { Invoke-InstallCanopy } })
$u.btnCanopyGet.Add_Click({ Invoke-Safe { Start-Process 'https://github.com/acidanthera/OpenCorePkg/releases' } })
$u.btnGetThemes.Add_Click({ Invoke-Safe { Start-Process 'https://github.com/acidanthera/OcBinaryData' } })
$u.btnDupTheme.Add_Click({ Invoke-Safe { Invoke-DuplicateTheme } })
$u.btnImportTheme.Add_Click({ Invoke-Safe { Invoke-ImportTheme } })
$u.btnOpenTheme.Add_Click({ Invoke-Safe { Start-Process 'explorer.exe' ('"' + (Get-ThemeDir $script:Ctx.EfiOc (Get-CurrentThemeRel)) + '"') } })

$u.btnBgApply.Add_Click({ Invoke-Safe { Set-BgColor $script:UI.txtBgHex.Text.Trim() } })
$u.btnBgBlack.Add_Click({ Invoke-Safe { Set-BgColor '#000000' } })
$u.btnBgGray.Add_Click({ Invoke-Safe { Set-BgColor '#BFBFBF' } })
$u.btnBgSet.Add_Click({ Invoke-Safe { Invoke-SetBackground } })
$u.btnBgRemove.Add_Click({ Invoke-Safe { Invoke-RemoveBackground } })

$u.cmbCatSource.Add_SelectionChanged({ if (-not $script:Loading) { Invoke-Safe { $script:Loading = $true; try { Update-CatalogGroups '' } finally { $script:Loading = $false }; Update-CatalogList } } })
$u.cmbCatGroup.Add_SelectionChanged({ if (-not $script:Loading) { Invoke-Safe { Update-CatalogList } } })
$u.lstCatalog.Add_SelectionChanged({ if (-not $script:Loading) { Invoke-Safe { Update-CatalogInfo } } })
$u.btnCatApply.Add_Click({ Invoke-Safe { Invoke-CatalogInstall $true } })
$u.btnCatInstall.Add_Click({ Invoke-Safe { Invoke-CatalogInstall $false } })
$u.btnCatPreview.Add_Click({ Invoke-Safe { Show-CatalogPreview } })
$u.btnCatSource.Add_Click({ Invoke-Safe { $t = Get-SelectedCatalogTheme; if ($t) { Start-Process ([string](Get-Catalog).Sources[$t.Source].Url) } } })

$u.btnBackupFull.Add_Click({ Invoke-Safe { Invoke-FullBackup } })
$u.btnRestore.Add_Click({ Invoke-Safe { Invoke-Restore } })
$u.btnDeleteBackup.Add_Click({
    Invoke-Safe {
        $id = Get-SelectedBackupId
        if ($id -and (Show-Confirm (T 'msgDelete'))) { Remove-Backup $id; Update-BackupList }
    }
})
$u.btnOpenBackups.Add_Click({
    Invoke-Safe {
        if (-not (Test-Path -LiteralPath $script:BackupRoot)) { [void](New-Item -ItemType Directory -Path $script:BackupRoot -Force) }
        Start-Process 'explorer.exe' ('"' + $script:BackupRoot + '"')
    }
})

$script:Win.Add_Closing({
    param($s, $e)
    if ($script:CatalogBusy) { $e.Cancel = $true; return }
    if ($script:ForceClose -or $SelfTest) { return }
    try { Update-StateFromUi } catch { }
    if (-not (Test-CanDiscard)) { $e.Cancel = $true }
})

# ---------------------------------------------------------------------------------------------
#  Demarrage
# ---------------------------------------------------------------------------------------------
$lang = $script:Settings.Lang
if (-not $lang) {
    $lang = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
    if (-not $script:Strings.ContainsKey($lang)) { $lang = 'en' }
}
$script:Loading = $true
[void](Select-ComboValue $u.cmbLang $lang)
$script:Loading = $false
Update-Swatches
Set-Language $lang
$u.lstNav.SelectedIndex = 0

$startPath = $null
if ($EfiPath) { $startPath = $EfiPath }
elseif ($script:Settings.LastEfi -and (Test-Path -LiteralPath (Join-Path $script:Settings.LastEfi 'config.plist'))) { $startPath = $script:Settings.LastEfi }
else {
    $found = @(Find-EfiFolders)
    if ($found.Count -gt 0) { $startPath = $found[0] }
}
if ($startPath) { Invoke-Safe { Open-Efi $startPath } }

# ---------------------------------------------------------------------------------------------
#  Auto-test (captures d'ecran + journal) : a lancer uniquement sur une copie de l'EFI
# ---------------------------------------------------------------------------------------------
if ($SelfTest) {
    if (-not (Test-Path -LiteralPath $SelfTest)) { [void](New-Item -ItemType Directory -Path $SelfTest -Force) }
    $script:TestLog = Join-Path $SelfTest 'selftest.log'
    Set-Content -LiteralPath $script:TestLog -Value ("selftest " + (Get-Date).ToString('s')) -Encoding UTF8
    $script:TestStep = 0

    function Add-TestLog([string]$Text) { Add-Content -LiteralPath $script:TestLog -Value $Text -Encoding UTF8 }

    function Save-Capture([string]$Name) {
        $root = $script:Win.Content
        $w = [int][Math]::Ceiling($root.ActualWidth); $h = [int][Math]::Ceiling($root.ActualHeight)
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($root)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create((Join-Path $SelfTest ($Name + '.png')))
        try { $enc.Save($fs) } finally { $fs.Dispose() }
        Add-TestLog "capture $Name ${w}x${h}"
    }

    function Invoke-TestStep([string]$Name, [scriptblock]$Block) {
        try { & $Block; Add-TestLog "OK   $Name" }
        catch { Add-TestLog ("FAIL $Name : " + $_.Exception.Message + "`n" + $_.ScriptStackTrace) }
    }

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(900)
    $timer.Add_Tick({
        $script:TestStep++
        $n = $script:TestStep
        if ($n -eq 1) {
            Add-TestLog ("ctx=" + [bool]$script:Ctx + " lang=" + $script:Lang)
            Invoke-TestStep 'capture style' { Save-Capture '1-style' }
            Invoke-TestStep 'select External' { $script:UI.rbExternal.IsChecked = $true; & $script:OnChange }
        } elseif ($n -eq 2) {
            Invoke-TestStep 'capture external' { Save-Capture '2-external' }
            Invoke-TestStep 'page theme' { $script:UI.lstNav.SelectedIndex = 1 }
        } elseif ($n -eq 3) {
            Invoke-TestStep 'capture theme' { Save-Capture '3-theme' }
            Invoke-TestStep 'duplicate theme' {
                $new = Copy-ThemeFolder $script:Ctx.EfiOc (Get-ThemeDir $script:Ctx.EfiOc (Get-CurrentThemeRel)) 'SelfTest' 'duplicate-theme'
                Select-Theme $new
            }
            Invoke-TestStep 'set background' {
                $src = Join-Path $SelfTest 'bg-source.png'
                $dv = New-Object System.Windows.Media.DrawingVisual
                $dc = $dv.RenderOpen()
                $grad = New-Object System.Windows.Media.LinearGradientBrush([System.Windows.Media.Colors]::DarkSlateBlue, [System.Windows.Media.Colors]::Teal, 45)
                $dc.DrawRectangle($grad, $null, (New-Object System.Windows.Rect(0, 0, 800, 600)))
                $dc.Close()
                $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(800, 600, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
                $rtb.Render($dv)
                $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
                $fs = [IO.File]::Create($src); try { $enc.Save($fs) } finally { $fs.Dispose() }
                [void](Set-ThemeBackground $script:Ctx.EfiOc (Get-CurrentThemeRel) $src 1920 1080)
                [void](Set-ThemeIcon $script:Ctx.EfiOc (Get-CurrentThemeRel) 'Other' $src)
                $script:TilesStamp++
                Update-Derived
            }
        } elseif ($n -eq 4) {
            Invoke-TestStep 'capture custom theme' { Save-Capture '4-custom-theme' }
            Invoke-TestStep 'page options' { $script:UI.lstNav.SelectedIndex = 3; $script:UI.chkHideAux.IsChecked = $false; $script:UI.txtTimeout.Text = '8'; & $script:OnChange }
        } elseif ($n -eq 5) {
            Invoke-TestStep 'capture options' { Save-Capture '5-options' }
            Invoke-TestStep 'colour' { Set-BgColor '#0B1F3A' }
            Invoke-TestStep 'save' { Invoke-Save; Add-TestLog ("state after save: " + (($script:Ctx.State.GetEnumerator() | Sort-Object Key | ForEach-Object { $_.Key + '=' + $_.Value }) -join '; ')) }
            Invoke-TestStep 'full backup' { Invoke-FullBackup }
            Invoke-TestStep 'page backups' { $script:UI.lstNav.SelectedIndex = 4 }
        } elseif ($n -eq 6) {
            Invoke-TestStep 'capture backups' { Save-Capture '6-backups' }
            Invoke-TestStep 'page catalogue' {
                $script:UI.lstNav.SelectedIndex = 2
                foreach ($it in $script:UI.lstCatalog.Items) { if ([string]$it.Tag -eq 'blackosx-set3-aqua') { $script:UI.lstCatalog.SelectedItem = $it } }
                Invoke-CatalogInstall $true
            }
        } elseif ($n -eq 7) {
            Invoke-TestStep 'capture catalogue' { Save-Capture '7-catalogue' }
            Invoke-TestStep 'language nl' { Set-Language 'nl'; $script:UI.lstNav.SelectedIndex = 0 }
        } elseif ($n -eq 8) {
            Invoke-TestStep 'capture nl' { Save-Capture '8-nl' }
            Add-TestLog 'DONE'
            $s = $args[0]; $s.Stop()
            $script:Win.Close()
        }
    })
    $script:Win.Add_ContentRendered({ $timer.Start() })
}

[void]$script:Win.ShowDialog()
