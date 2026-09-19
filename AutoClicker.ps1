# ============================================================
#  简单连点器 v3.1（参考手机"自动点击器"）
#  功能：
#   1. 多任务点：按顺序循环执行，每任务独立 坐标/按键/类型/延时/偏移
#   2. 点击类型：单击 / 双击 / 长按(500ms)；按键：左/右/中键
#   3. 随机延时：任务延时支持区间写法，如 "1~3" = 每次随机 1~3 秒
#   4. 随机偏移：每任务可设 ±N 像素，点击位置随机抖动
#   5. 执行轮数限制（0=无限）+ 轮间间隔 + 开始前倒计时
#   6. 预设方案：可保存多套配置到 presets 文件夹，随时加载/删除
#   7. 全局热键：F9 开始/停止 · F10 拾取位置 · F11 添加任务 · F12 保存预设
#   8. 配置自动保存（config.json），下次打开自动恢复
#  使用：双击同目录「启动连点器.bat」，零依赖、绿色无害
# ============================================================

# ---------- 1. 加载系统组件 ----------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# ---------- 2. 底层接口（user32.dll）：鼠标模拟（SendInput）+ 全局按键检测 ----------
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MouseSim {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public MOUSEINPUT mi;
    }
    [DllImport("user32.dll")]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    // 检测"自上次调用后是否被按下过"（低位标志，轮询不漏检）
    public static bool WasKeyPressed(int vKey) {
        return (GetAsyncKeyState(vKey) & 0x0001) != 0;
    }

    public static void MoveTo(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(50);
    }

    // btn : 1=左键 2=右键 3=中键 ; type: 1=单击 2=双击 3=长按
    public static void Click(int btn, int type) {
        uint down = 0, up = 0;
        if (btn == 1)      { down = 0x0002; up = 0x0004; }   // LEFTDOWN / LEFTUP
        else if (btn == 2) { down = 0x0008; up = 0x0010; }   // RIGHTDOWN / RIGHTUP
        else               { down = 0x0020; up = 0x0040; }   // MIDDLEDOWN / MIDDLEUP

        int holdMs = (type == 3) ? 500 : 0;   // 长按保持 500ms

        INPUT[] inp = new INPUT[1];
        inp[0].type = 0;                       // INPUT_MOUSE
        inp[0].mi.dx = 0;
        inp[0].mi.dy = 0;
        inp[0].mi.mouseData = 0;
        inp[0].mi.time = 0;
        inp[0].mi.dwExtraInfo = IntPtr.Zero;
        int cb = Marshal.SizeOf(inp[0]);

        // 按下
        inp[0].mi.dwFlags = down;
        SendInput(1, inp, cb);
        if (holdMs > 0) System.Threading.Thread.Sleep(holdMs);
        // 抬起
        inp[0].mi.dwFlags = up;
        SendInput(1, inp, cb);

        // 双击：间隔后再来一次
        if (type == 2) {
            System.Threading.Thread.Sleep(60);
            inp[0].mi.dwFlags = down; SendInput(1, inp, cb);
            inp[0].mi.dwFlags = up;   SendInput(1, inp, cb);
        }
    }
}
"@

# ---------- 3. 应用目录：配置统一存 %APPDATA%\SimpleAutoClicker\，不污染桌面/exe 旁边 ----------
$script:appDir = Join-Path $env:APPDATA "SimpleAutoClicker"
if (-not (Test-Path $script:appDir)) { New-Item -ItemType Directory -Path $script:appDir -Force | Out-Null }
$script:cfgPath = Join-Path $script:appDir "config.json"
$script:presetDir = Join-Path $script:appDir "presets"

# ---------- 4. 工具函数：解析延时（支持 "2" 或 "1~3" 区间随机） ----------
function Get-RandomDelay([string]$s) {
    if ($s -match '^\s*([0-9]+(?:\.[0-9]+)?)\s*~\s*([0-9]+(?:\.[0-9]+)?)\s*$') {
        $lo = [double]$Matches[1]; $hi = [double]$Matches[2]
        if ($lo -le $hi -and $lo -ge 0.1) {
            return [math]::Round($lo + (Get-Random -Maximum 10000) / 10000.0 * ($hi - $lo), 2)
        }
        return $null
    }
    $d = 0.0
    if ([double]::TryParse($s, [ref]$d) -and $d -ge 0.1) { return $d }
    return $null
}

function Test-DelayString([string]$s) {
    return $null -ne (Get-RandomDelay $s)
}

# ---------- 5. 创建主窗口 ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "简单连点器 v3.3"
$form.Size = New-Object System.Drawing.Size(680, 560)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false

# ---------- 6. 任务列表 ----------
$lblTasks = New-Object System.Windows.Forms.Label
$lblTasks.Text = "点击任务（按顺序循环执行，延时支持区间如 1~3 = 随机 1~3 秒）："
$lblTasks.Location = New-Object System.Drawing.Point(12, 10)
$lblTasks.Size = New-Object System.Drawing.Size(620, 22)

$dgv = New-Object System.Windows.Forms.DataGridView
$dgv.Location = New-Object System.Drawing.Point(12, 36)
$dgv.Size = New-Object System.Drawing.Size(640, 240)
$dgv.AllowUserToAddRows = $true
$dgv.AllowUserToDeleteRows = $true
$dgv.RowHeadersVisible = $false
$dgv.SelectionMode = "FullRowSelect"
$dgv.MultiSelect = $false
$dgv.AutoSizeColumnsMode = "Fill"
$dgv.BackgroundColor = [System.Drawing.Color]::White

$dgv.Columns.Add("colX", "X坐标") | Out-Null
$dgv.Columns.Add("colY", "Y坐标") | Out-Null

$colBtn = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
$colBtn.Name = "colBtn"; $colBtn.HeaderText = "按键"
$colBtn.Items.Add("左键") | Out-Null
$colBtn.Items.Add("右键") | Out-Null
$colBtn.Items.Add("中键") | Out-Null
$colBtn.DefaultCellStyle.NullValue = "左键"
$dgv.Columns.Add($colBtn) | Out-Null

$colType = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
$colType.Name = "colType"; $colType.HeaderText = "类型"
$colType.Items.Add("单击") | Out-Null
$colType.Items.Add("双击") | Out-Null
$colType.Items.Add("长按") | Out-Null
$colType.DefaultCellStyle.NullValue = "单击"
$dgv.Columns.Add($colType) | Out-Null

$dgv.Columns.Add("colDelay", "延时(秒)") | Out-Null
$dgv.Columns.Add("colOffset", "偏移(px)") | Out-Null

$form.Controls.Add($lblTasks)
$form.Controls.Add($dgv)

# ---------- 7. 任务操作按钮 ----------
function Add-TaskRow([int]$x, [int]$y) {
    $idx = $dgv.Rows.Add($x, $y, "左键", "单击", 1.0, 0)
    $dgv.CurrentCell = $dgv.Rows[$idx].Cells["colX"]
}

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = "添加任务"
$btnAdd.Location = New-Object System.Drawing.Point(12, 286)
$btnAdd.Size = New-Object System.Drawing.Size(90, 30)
$btnAdd.Add_Click({ Add-TaskRow 0 0 })

$btnPick = New-Object System.Windows.Forms.Button
$btnPick.Text = "拾取位置 (F10)"
$btnPick.Location = New-Object System.Drawing.Point(108, 286)
$btnPick.Size = New-Object System.Drawing.Size(110, 30)
$btnPick.Add_Click({
    $pos = [System.Windows.Forms.Cursor]::Position
    if ($dgv.CurrentRow -and -not $dgv.CurrentRow.IsNewRow) {
        $dgv.CurrentRow.Cells["colX"].Value = $pos.X
        $dgv.CurrentRow.Cells["colY"].Value = $pos.Y
    } else {
        Add-TaskRow $pos.X $pos.Y
    }
})

$btnDel = New-Object System.Windows.Forms.Button
$btnDel.Text = "删除选中"
$btnDel.Location = New-Object System.Drawing.Point(224, 286)
$btnDel.Size = New-Object System.Drawing.Size(90, 30)
$btnDel.Add_Click({
    if ($dgv.CurrentRow -and -not $dgv.CurrentRow.IsNewRow) {
        $dgv.Rows.Remove($dgv.CurrentRow)
    }
})

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = "清空全部"
$btnClear.Location = New-Object System.Drawing.Point(320, 286)
$btnClear.Size = New-Object System.Drawing.Size(90, 30)
$btnClear.Add_Click({ $dgv.Rows.Clear() })

$form.Controls.Add($btnAdd)
$form.Controls.Add($btnPick)
$form.Controls.Add($btnDel)
$form.Controls.Add($btnClear)

# ---------- 8. 运行设置区 ----------
$lblRounds = New-Object System.Windows.Forms.Label
$lblRounds.Text = "执行轮数(0=无限)："
$lblRounds.Location = New-Object System.Drawing.Point(12, 340)
$lblRounds.Size = New-Object System.Drawing.Size(125, 25)

$txtRounds = New-Object System.Windows.Forms.TextBox
$txtRounds.Text = "0"
$txtRounds.Location = New-Object System.Drawing.Point(140, 337)
$txtRounds.Size = New-Object System.Drawing.Size(50, 25)

$lblGap = New-Object System.Windows.Forms.Label
$lblGap.Text = "轮间间隔(秒)："
$lblGap.Location = New-Object System.Drawing.Point(200, 340)
$lblGap.Size = New-Object System.Drawing.Size(105, 25)

$txtGap = New-Object System.Windows.Forms.TextBox
$txtGap.Text = "0"
$txtGap.Location = New-Object System.Drawing.Point(308, 337)
$txtGap.Size = New-Object System.Drawing.Size(50, 25)

$lblCountdown = New-Object System.Windows.Forms.Label
$lblCountdown.Text = "开始倒计时(秒)："
$lblCountdown.Location = New-Object System.Drawing.Point(370, 340)
$lblCountdown.Size = New-Object System.Drawing.Size(115, 25)

$txtCountdown = New-Object System.Windows.Forms.TextBox
$txtCountdown.Text = "3"
$txtCountdown.Location = New-Object System.Drawing.Point(488, 337)
$txtCountdown.Size = New-Object System.Drawing.Size(50, 25)

$form.Controls.Add($lblRounds)
$form.Controls.Add($txtRounds)
$form.Controls.Add($lblGap)
$form.Controls.Add($txtGap)
$form.Controls.Add($lblCountdown)
$form.Controls.Add($txtCountdown)

# ---------- 9. 预设方案区 ----------
$lblPreset = New-Object System.Windows.Forms.Label
$lblPreset.Text = "预设："
$lblPreset.Location = New-Object System.Drawing.Point(12, 374)
$lblPreset.Size = New-Object System.Drawing.Size(50, 25)

$cmbPreset = New-Object System.Windows.Forms.ComboBox
$cmbPreset.Location = New-Object System.Drawing.Point(62, 371)
$cmbPreset.Size = New-Object System.Drawing.Size(200, 25)
$cmbPreset.DropDownStyle = "DropDownList"

$btnSavePreset = New-Object System.Windows.Forms.Button
$btnSavePreset.Text = "保存 (F12)"
$btnSavePreset.Location = New-Object System.Drawing.Point(270, 371)
$btnSavePreset.Size = New-Object System.Drawing.Size(90, 30)

$btnLoadPreset = New-Object System.Windows.Forms.Button
$btnLoadPreset.Text = "加载"
$btnLoadPreset.Location = New-Object System.Drawing.Point(365, 371)
$btnLoadPreset.Size = New-Object System.Drawing.Size(60, 30)

$btnDelPreset = New-Object System.Windows.Forms.Button
$btnDelPreset.Text = "删除"
$btnDelPreset.Location = New-Object System.Drawing.Point(430, 371)
$btnDelPreset.Size = New-Object System.Drawing.Size(60, 30)

$form.Controls.Add($lblPreset)
$form.Controls.Add($cmbPreset)
$form.Controls.Add($btnSavePreset)
$form.Controls.Add($btnLoadPreset)
$form.Controls.Add($btnDelPreset)

# ---------- 10. 热键提示 + 状态栏 + 开始按钮 ----------
$lblHotkey = New-Object System.Windows.Forms.Label
$lblHotkey.Text = "热键：F9 开始/停止 · F10 拾取位置 · F11 添加任务 · F12 保存预设"
$lblHotkey.Location = New-Object System.Drawing.Point(12, 412)
$lblHotkey.Size = New-Object System.Drawing.Size(620, 25)
$lblHotkey.ForeColor = [System.Drawing.Color]::DarkBlue

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "就绪：添加任务后按 F9 或点「开始」"
$lblStatus.Location = New-Object System.Drawing.Point(12, 445)
$lblStatus.Size = New-Object System.Drawing.Size(620, 25)
$lblStatus.ForeColor = [System.Drawing.Color]::Gray

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "开始  (F9)"
$btnStart.Location = New-Object System.Drawing.Point(12, 480)
$btnStart.Size = New-Object System.Drawing.Size(150, 45)

$form.Controls.Add($lblHotkey)
$form.Controls.Add($lblStatus)
$form.Controls.Add($btnStart)

# ---------- 11. 配置读写（供自动保存 / 预设共用） ----------
function Save-CfgToFile([string]$path) {
    $rows = @()
    foreach ($r in $dgv.Rows) {
        if ($r.IsNewRow) { continue }
        $rows += [pscustomobject]@{
            X      = [string]$r.Cells["colX"].Value
            Y      = [string]$r.Cells["colY"].Value
            Btn    = [string]$r.Cells["colBtn"].Value
            Type   = [string]$r.Cells["colType"].Value
            Delay  = [string]$r.Cells["colDelay"].Value
            Offset = [string]$r.Cells["colOffset"].Value
        }
    }
    $cfg = [pscustomobject]@{
        Rounds = $txtRounds.Text
        Gap    = $txtGap.Text
        Countdown = $txtCountdown.Text
        Tasks  = $rows
    }
    try { $cfg | ConvertTo-Json -Depth 4 | Set-Content -Path $path -Encoding UTF8 } catch {}
}

function Load-CfgFromFile([string]$path) {
    if (-not (Test-Path $path)) { return $false }
    try {
        $cfg = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.Rounds) { $txtRounds.Text = [string]$cfg.Rounds }
        if ($cfg.Gap) { $txtGap.Text = [string]$cfg.Gap }
        if ($cfg.Countdown) { $txtCountdown.Text = [string]$cfg.Countdown }
        $dgv.Rows.Clear()
        if ($cfg.Tasks) {
            foreach ($t in $cfg.Tasks) {
                $dgv.Rows.Add([string]$t.X, [string]$t.Y, [string]$t.Btn, [string]$t.Type, [string]$t.Delay, [string]$t.Offset) | Out-Null
            }
        }
        return $true
    } catch { return $false }
}

# ---------- 12. 预设管理 ----------
function Refresh-PresetList {
    $cmbPreset.Items.Clear()
    if (Test-Path $script:presetDir) {
        Get-ChildItem $script:presetDir -Filter "*.json" | ForEach-Object { $cmbPreset.Items.Add($_.BaseName) | Out-Null }
    }
}

function Save-Preset {
    $name = [Microsoft.VisualBasic.Interaction]::InputBox("请输入预设名称：", "保存预设", "预设1")
    $name = $name.Trim()
    if (-not $name) { return }
    if (-not (Test-Path $script:presetDir)) { New-Item -ItemType Directory -Path $script:presetDir -Force | Out-Null }
    $path = Join-Path $script:presetDir ($name + ".json")
    Save-CfgToFile $path
    Refresh-PresetList
    $cmbPreset.SelectedItem = $name
    $lblStatus.Text = "已保存预设「$name」"
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
}

function Load-Preset {
    if ($null -eq $cmbPreset.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("请先在列表里选择一个预设", "提示")
        return
    }
    $name = [string]$cmbPreset.SelectedItem
    $path = Join-Path $script:presetDir ($name + ".json")
    if (Load-CfgFromFile $path) {
        $lblStatus.Text = "已加载预设「$name」"
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        [System.Windows.Forms.MessageBox]::Show("加载失败，文件可能已损坏", "错误")
    }
}

function Delete-Preset {
    if ($null -eq $cmbPreset.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("请先在列表里选择一个预设", "提示")
        return
    }
    $name = [string]$cmbPreset.SelectedItem
    $r = [System.Windows.Forms.MessageBox]::Show("确定删除预设「$name」吗？", "确认删除",
         [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        Remove-Item (Join-Path $script:presetDir ($name + ".json")) -Force -ErrorAction SilentlyContinue
        Refresh-PresetList
        $lblStatus.Text = "已删除预设「$name」"
        $lblStatus.ForeColor = [System.Drawing.Color]::Gray
    }
}

$btnSavePreset.Add_Click({ Save-Preset })
$btnLoadPreset.Add_Click({ Load-Preset })
$btnDelPreset.Add_Click({ Delete-Preset })

# ---------- 13. 运行状态机 ----------
$script:running = $false
$script:phase = ""
$script:curRow = 0
$script:waitMs = 0
$script:cdLeft = 0
$script:betweenLeft = 0
$script:doneRounds = 0
$script:totalClicks = 0
$script:taskCount = 0
$script:maxRounds = 0
$script:gapSec = 0.0
$script:tasks = @()

function Update-Status {
    if ($script:phase -eq "countdown") {
        $sec = [math]::Ceiling($script:cdLeft / 10)
        $lblStatus.Text = "倒计时：$sec 秒后开始执行（按 F9 取消）"
    } elseif ($script:phase -eq "between") {
        $sec = [math]::Ceiling($script:betweenLeft / 10)
        $lblStatus.Text = "轮间等待：$sec 秒 · 已完成 $($script:doneRounds) 轮 · 共 $($script:totalClicks) 次点击 · F9 停止"
    } else {
        $lblStatus.Text = "运行中：任务 $($script:curRow+1)/$($script:taskCount) · 第 $($script:doneRounds+1) 轮 · 共 $($script:totalClicks) 次点击 · F9 停止"
    }
}

$runTimer = New-Object System.Windows.Forms.Timer
$runTimer.Interval = 100

$runTimer.Add_Tick({
    if (-not $script:running) { return }

    if ($script:phase -eq "countdown") {
        $script:cdLeft--
        if ($script:cdLeft -le 0) {
            $script:phase = "run"
            $script:curRow = 0
            $script:waitMs = 0
        }
        Update-Status
        return
    }

    if ($script:phase -eq "between") {
        $script:betweenLeft--
        if ($script:betweenLeft -le 0) {
            $script:phase = "run"
            $script:curRow = 0
            $script:waitMs = 0
        }
        Update-Status
        return
    }

    # ---- 执行阶段 ----
    if ($script:waitMs -gt 0) {
        $script:waitMs -= 100
        if ($script:waitMs -lt 0) { $script:waitMs = 0 }
        return
    }

    $t = $script:tasks[$script:curRow]
    $delay = Get-RandomDelay $t.DelayRaw
    if ($null -eq $delay) { $delay = 1.0 }

    $ox = 0; $oy = 0
    if ($t.Offset -gt 0) {
        $ox = Get-Random -Minimum (-$t.Offset) -Maximum ($t.Offset + 1)
        $oy = Get-Random -Minimum (-$t.Offset) -Maximum ($t.Offset + 1)
    }

    [MouseSim]::MoveTo($t.X + $ox, $t.Y + $oy)
    [MouseSim]::Click($t.Btn, $t.Type)
    $script:totalClicks++
    $script:waitMs = [int]($delay * 1000)

    $script:curRow++
    if ($script:curRow -ge $script:taskCount) {
        $script:curRow = 0
        $script:doneRounds++
        if ($script:maxRounds -gt 0 -and $script:doneRounds -ge $script:maxRounds) {
            Stop-Clicker
            return
        }
        if ($script:gapSec -gt 0) {
            $script:phase = "between"
            $script:betweenLeft = [int]($script:gapSec * 10)
        }
    }
    Update-Status
})

# ---------- 14. 开始 / 停止 ----------
function Start-Clicker {
    $list = @()
    foreach ($r in $dgv.Rows) {
        if ($r.IsNewRow) { continue }
        $x = 0; $y = 0; $off = 0
        if (-not [int]::TryParse([string]$r.Cells["colX"].Value, [ref]$x) -or
            -not [int]::TryParse([string]$r.Cells["colY"].Value, [ref]$y)) {
            [System.Windows.Forms.MessageBox]::Show("X/Y 坐标必须是整数，请检查任务列表", "输入有误")
            return
        }
        $delayRaw = ([string]$r.Cells["colDelay"].Value).Trim()
        if (-not (Test-DelayString $delayRaw)) {
            [System.Windows.Forms.MessageBox]::Show("延时格式不对（第 $($r.Index+1) 行）：应为数字或区间，如 2 或 1~3", "输入有误")
            return
        }
        $offTxt = [string]$r.Cells["colOffset"].Value
        if ($offTxt) {
            if (-not [int]::TryParse($offTxt, [ref]$off) -or $off -lt 0 -or $off -gt 100) {
                [System.Windows.Forms.MessageBox]::Show("偏移(px)必须是 0~100 的整数（第 $($r.Index+1) 行）", "输入有误")
                return
            }
        }
        $btnName = [string]$r.Cells["colBtn"].Value
        $typeName = [string]$r.Cells["colType"].Value
        if (-not $btnName) { $btnName = "左键" }
        if (-not $typeName) { $typeName = "单击" }
        $b = 1; if ($btnName -eq "右键") { $b = 2 } elseif ($btnName -eq "中键") { $b = 3 }
        $tp = 1; if ($typeName -eq "双击") { $tp = 2 } elseif ($typeName -eq "长按") { $tp = 3 }
        $list += [pscustomobject]@{ X = $x; Y = $y; Btn = $b; Type = $tp; DelayRaw = $delayRaw; Offset = $off }
    }
    if ($list.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("请先添加至少一个点击任务", "提示")
        return
    }

    $rounds = 0
    if (-not [int]::TryParse($txtRounds.Text, [ref]$rounds) -or $rounds -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("执行轮数必须是大于等于 0 的整数（0 = 无限）", "输入有误")
        return
    }
    $gap = 0.0
    if (-not [double]::TryParse($txtGap.Text, [ref]$gap) -or $gap -lt 0 -or $gap -gt 600) {
        [System.Windows.Forms.MessageBox]::Show("轮间间隔必须是 0~600 秒", "输入有误")
        return
    }
    $cd = 0
    if (-not [int]::TryParse($txtCountdown.Text, [ref]$cd) -or $cd -lt 0 -or $cd -gt 60) {
        [System.Windows.Forms.MessageBox]::Show("倒计时必须是 0~60 秒的整数（0 = 立即开始）", "输入有误")
        return
    }

    $dgv.ReadOnly = $true
    $dgv.AllowUserToAddRows = $false
    $btnAdd.Enabled = $false; $btnPick.Enabled = $false
    $btnDel.Enabled = $false; $btnClear.Enabled = $false
    $txtRounds.Enabled = $false; $txtGap.Enabled = $false; $txtCountdown.Enabled = $false
    $btnSavePreset.Enabled = $false; $btnLoadPreset.Enabled = $false; $btnDelPreset.Enabled = $false
    $cmbPreset.Enabled = $false

    $script:tasks = $list
    $script:taskCount = $list.Count
    $script:maxRounds = $rounds
    $script:gapSec = $gap
    $script:curRow = 0
    $script:waitMs = 0
    $script:doneRounds = 0
    $script:totalClicks = 0
    $script:running = $true
    $btnStart.Text = "停止  (F9)"
    $lblStatus.ForeColor = [System.Drawing.Color]::Green

    if ($cd -gt 0) {
        $script:phase = "countdown"
        $script:cdLeft = $cd * 10
        Update-Status
    } else {
        $script:phase = "run"
        Update-Status
    }
    $runTimer.Start()
}

function Stop-Clicker {
    $script:running = $false
    $script:phase = ""
    $runTimer.Stop()
    $dgv.ReadOnly = $false
    $dgv.AllowUserToAddRows = $true
    $btnAdd.Enabled = $true; $btnPick.Enabled = $true
    $btnDel.Enabled = $true; $btnClear.Enabled = $true
    $txtRounds.Enabled = $true; $txtGap.Enabled = $true; $txtCountdown.Enabled = $true
    $btnSavePreset.Enabled = $true; $btnLoadPreset.Enabled = $true; $btnDelPreset.Enabled = $true
    $cmbPreset.Enabled = $true
    $btnStart.Text = "开始  (F9)"
    $lblStatus.Text = "已停止（共 $($script:doneRounds) 轮、$($script:totalClicks) 次点击）"
    $lblStatus.ForeColor = [System.Drawing.Color]::Gray
}

$btnStart.Add_Click({
    if ($script:running) { Stop-Clicker } else { Start-Clicker }
})

# ---------- 15. 全局热键 F9~F12 ----------
$hotkeyTimer = New-Object System.Windows.Forms.Timer
$hotkeyTimer.Interval = 100
$hotkeyTimer.Add_Tick({
    # F9：开始 / 停止
    if ([MouseSim]::WasKeyPressed(0x78)) {
        if ($script:running) { Stop-Clicker } else { Start-Clicker }
    }

    # F10：拾取鼠标位置（运行中不响应）
    if ([MouseSim]::WasKeyPressed(0x79) -and -not $script:running) {
        $pos = [System.Windows.Forms.Cursor]::Position
        if ($dgv.CurrentRow -and -not $dgv.CurrentRow.IsNewRow) {
            $dgv.CurrentRow.Cells["colX"].Value = $pos.X
            $dgv.CurrentRow.Cells["colY"].Value = $pos.Y
            $lblStatus.Text = "已拾取位置 ($($pos.X), $($pos.Y)) 填入选中任务"
        } else {
            Add-TaskRow $pos.X $pos.Y
            $lblStatus.Text = "已拾取位置 ($($pos.X), $($pos.Y))，新建任务"
        }
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
    }

    # F11：添加任务（运行中不响应）
    if ([MouseSim]::WasKeyPressed(0x7A) -and -not $script:running) {
        Add-TaskRow 0 0
        $lblStatus.Text = "已添加任务，把鼠标移到目标位置后按 F10 填入坐标"
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
    }

    # F12：保存预设
    if ([MouseSim]::WasKeyPressed(0x7B)) {
        Save-Preset
    }
})
$hotkeyTimer.Start()

# ---------- 16. 关闭时自动保存配置 ----------
$form.Add_FormClosing({
    $hotkeyTimer.Stop()
    if ($script:running) { Stop-Clicker }
    Save-CfgToFile $script:cfgPath
    [System.Environment]::Exit(0)
})

# ---------- 17. 启动 ----------
Refresh-PresetList
Load-CfgFromFile $script:cfgPath

# 检测是否以管理员权限运行（点管理员窗口需要提权）
$isAdmin = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $lblStatus.Text = "就绪（普通权限；若点不了管理员窗口/游戏，右键->以管理员身份运行）"
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
}

$form.ShowDialog()

