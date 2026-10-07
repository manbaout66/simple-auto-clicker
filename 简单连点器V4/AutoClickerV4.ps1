# ============================================================
#  简单连点器 v4.1（可视化版 · 参考"自动点击器-连点器"）
#  功能：
#   1. 可视化点击圈：全屏透明覆盖层，每个任务显示圆圈+序号（1、2、3…）
#   2. 圈圈交互：拖动改坐标 · 右键删除该任务 · 运行中当前点高亮
#   3. 运行时点击穿透：圈可见但完全不拦截鼠标，点击直达目标内容
#   4. 多任务点：按顺序循环执行，每任务独立 坐标/按键/类型/延时/偏移
#   5. 点击类型：单击 / 双击 / 长按(500ms)；按键：左/右/中键
#   6. 随机延时：任务延时支持区间写法，如 "1~3" = 每次随机 1~3 秒
#   7. 随机偏移：每任务可设 ±N 像素，点击位置随机抖动
#   8. 执行轮数限制（0=无限）+ 轮间间隔 + 开始前倒计时
#   9. 预设方案：下拉框选中即加载，新建 / 保存(覆盖当前) / 删除
#  10. 全局热键：F9 开始/停止 · F10 拾取位置 · F11 添加任务 · F12 保存当前预设
#  11. 配置自动保存（%APPDATA%\SimpleAutoClickerV4\config.json）
#  使用：双击 exe 或同目录「启动连点器V4.bat」，零依赖、绿色无害
# ============================================================



# ---------- 1. 加载系统组件 ----------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# ---------- 2. 开启 DPI 感知：所有坐标统一为物理像素（否则高DPI下位置偏移 25%） ----------
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DpiHelper {
    // -4 = PER_MONITOR_AWARE_V2：Win10+ 最强 DPI 感知
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
}
"@
[DpiHelper]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

# ---------- 3. 底层接口（user32.dll）：鼠标模拟（SendInput）+ 全局按键检测 ----------
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

    public static bool WasKeyPressed(int vKey) {
        return (GetAsyncKeyState(vKey) & 0x0001) != 0;
    }

    public static void MoveTo(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(50);
    }

    public static void Click(int btn, int type) {
        uint down = 0, up = 0;
        if (btn == 1)      { down = 0x0002; up = 0x0004; }
        else if (btn == 2) { down = 0x0008; up = 0x0010; }
        else               { down = 0x0020; up = 0x0040; }

        int holdMs = (type == 3) ? 500 : 0;

        INPUT[] inp = new INPUT[1];
        inp[0].type = 0;
        inp[0].mi.dx = 0;
        inp[0].mi.dy = 0;
        inp[0].mi.mouseData = 0;
        inp[0].mi.time = 0;
        inp[0].mi.dwExtraInfo = IntPtr.Zero;
        int cb = Marshal.SizeOf(inp[0]);

        inp[0].mi.dwFlags = down;
        SendInput(1, inp, cb);
        if (holdMs > 0) System.Threading.Thread.Sleep(holdMs);
        inp[0].mi.dwFlags = up;
        SendInput(1, inp, cb);

        if (type == 2) {
            System.Threading.Thread.Sleep(60);
            inp[0].mi.dwFlags = down; SendInput(1, inp, cb);
            inp[0].mi.dwFlags = up;   SendInput(1, inp, cb);
        }
    }
}
"@

# ---------- 4. 可视化点击圈：全屏透明覆盖层（参考"自动点击器-连点器"） ----------
#  · 圈画在覆盖层上，覆盖层 TopMost 永远在最上
#  · 运行时 Locked=true：WM_NCHITTEST 全穿透，点击直达目标内容（圈不挡鼠标）
#  · 停止时 Locked=false：圈内可拖动改坐标、右键删除
Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class CircleOverlay : Form {
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);

    public static PointF[] Pts = new PointF[0];   // 所有任务点（屏幕坐标）
    public static int Current = -1;                // 运行时高亮序号（-1 = 无）
    private static bool _locked = false;           // 运行中：穿透 + 锁交互
    private static CircleOverlay _inst = null;     // 单例实例（SetPenetrate 用）
    public static Action<int,int,int> OnMoved;     // 拖放完成回调 (index, x, y)
    public static Action<int> OnRight;             // 右键回调 (index)

    private static Font F = new Font("Arial", 11f, FontStyle.Bold);
    private const int HIT_R = 26;                  // 命中半径（拖/右键判定）
    private bool dragging = false;
    private int dragIdx = -1;
    private PointF dragOff;

    // Locked 属性：运行时=true 时给覆盖层加 WS_EX_TRANSPARENT（系统级鼠标穿透，
    // 点击直达目标窗口——这是跨进程穿透的正确方式）；
    // 停止时=false 去掉穿透，圈内恢复拖动/右键交互。
    public static bool Locked {
        get { return _locked; }
        set { _locked = value; if (_inst != null) _inst.SetPenetrate(value); }
    }

    public CircleOverlay() {
        this.FormBorderStyle = FormBorderStyle.None;
        this.ShowInTaskbar = false;
        this.TopMost = true;
        this.StartPosition = FormStartPosition.Manual;
        Rectangle sc = Screen.PrimaryScreen.Bounds;
        this.SetBounds(0, 0, sc.Width, sc.Height);
        this.BackColor = Color.Magenta;
        this.TransparencyKey = Color.Magenta;      // 整层透明，只显示画上去的圈
        this.DoubleBuffered = true;
        this.Cursor = Cursors.SizeAll;
        _inst = this;
        // WS_EX_NOACTIVATE：点击不抢焦点；WS_EX_TOOLWINDOW：不进任务栏
        this.HandleCreated += delegate {
            int ex = GetWindowLong(this.Handle, -20);
            SetWindowLong(this.Handle, -20, ex | 0x08000000 | 0x00000080);
            if (_locked) SetPenetrate(true);
        };
    }

    // 动态切换鼠标穿透：WS_EX_TRANSPARENT (0x20) = 系统级点击穿透（跨进程有效）
    void SetPenetrate(bool p) {
        if (!this.IsHandleCreated) return;
        int ex = GetWindowLong(this.Handle, -20);
        if (p) ex |= 0x00000020; else ex &= ~0x00000020;
        SetWindowLong(this.Handle, -20, ex);
        this.Invalidate();
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x84) { // WM_NCHITTEST：命中测试决定鼠标穿透
            if (Locked) { m.Result = new IntPtr(-1); return; }        // 运行中全穿透
            Point scr = Cursor.Position;
            for (int i = 0; i < Pts.Length; i++) {
                double dx = scr.X - Pts[i].X, dy = scr.Y - Pts[i].Y;
                if (dx*dx + dy*dy <= HIT_R*HIT_R) { m.Result = new IntPtr(1); return; } // 圈内：可交互
            }
            m.Result = new IntPtr(-1); return;                         // 圈外：穿透
        }
        base.WndProc(ref m);
    }

    protected override void OnMouseDown(MouseEventArgs e) {
        base.OnMouseDown(e);
        if (Locked) return;
        PointF scr = new PointF(e.X, e.Y);   // 覆盖层全屏 (0,0) = 屏幕 (0,0)，客户区坐标即屏幕坐标
        if (e.Button == MouseButtons.Right) {
            for (int i = Pts.Length - 1; i >= 0; i--) {
                double dx = scr.X - Pts[i].X, dy = scr.Y - Pts[i].Y;
                if (dx*dx + dy*dy <= HIT_R*HIT_R) { if (OnRight != null) OnRight(i); return; }
            }
            return;
        }
        if (e.Button == MouseButtons.Left) {
            for (int i = Pts.Length - 1; i >= 0; i--) {
                double dx = scr.X - Pts[i].X, dy = scr.Y - Pts[i].Y;
                if (dx*dx + dy*dy <= HIT_R*HIT_R) {
                    dragging = true; dragIdx = i;
                    dragOff = new PointF(e.X - Pts[i].X, e.Y - Pts[i].Y);  // 保持按住点与圆心相对位置
                    return;
                }
            }
        }
    }

    protected override void OnMouseMove(MouseEventArgs e) {
        base.OnMouseMove(e);
        if (dragging && dragIdx >= 0) {
            Pts[dragIdx] = new PointF(e.X - dragOff.X, e.Y - dragOff.Y);
            this.Invalidate();
        }
    }

    protected override void OnMouseUp(MouseEventArgs e) {
        base.OnMouseUp(e);
        if (dragging) {
            dragging = false;
            int idx = dragIdx; dragIdx = -1;
            if (OnMoved != null && idx >= 0)
                OnMoved(idx, (int)Math.Round(Pts[idx].X), (int)Math.Round(Pts[idx].Y));
        }
    }

    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        Graphics g = e.Graphics;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        for (int i = 0; i < Pts.Length; i++) {
            float cx = Pts[i].X, cy = Pts[i].Y;
            if (cx < -30 || cy < -30 || cx > this.ClientSize.Width + 30 || cy > this.ClientSize.Height + 30) continue;
            bool hot = (Current == i);
            if (hot) {
                g.FillEllipse(Brushes.Yellow, cx - 20, cy - 20, 40, 40);          // 高亮黄晕
                g.FillEllipse(Brushes.LimeGreen, cx - 15, cy - 15, 30, 30);        // 绿色主体
                g.DrawEllipse(new Pen(Color.DarkGreen, 2f), cx - 15, cy - 15, 30, 30);
            } else {
                g.FillEllipse(Brushes.White, cx - 18, cy - 18, 36, 36);            // 白圆
                g.DrawEllipse(new Pen(Color.Black, 2f), cx - 18, cy - 18, 36, 36); // 黑边
            }
            string s = (i + 1).ToString();
            SizeF sz = g.MeasureString(s, F);
            g.DrawString(s, F, hot ? Brushes.White : Brushes.Black, cx - sz.Width / 2, cy - sz.Height / 2);
        }
    }
}
"@ -ReferencedAssemblies "System.Windows.Forms","System.Drawing"

# ---------- 5. 应用目录：配置存 %APPDATA%\SimpleAutoClickerV4\ ----------
$script:appDir = Join-Path $env:APPDATA "SimpleAutoClickerV4"
if (-not (Test-Path $script:appDir)) { New-Item -ItemType Directory -Path $script:appDir -Force | Out-Null }
$script:cfgPath = Join-Path $script:appDir "config.json"
$script:presetDir = Join-Path $script:appDir "presets"

# ---------- 6. 工具函数：解析延时（支持 "2" 或 "1~3" 区间随机） ----------
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

# ---------- 7. 创建主窗口（普通窗口：不抢 TopMost 层级，圈层永远在最上） ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "简单连点器 v4.1（可视化）"
$form.Size = New-Object System.Drawing.Size(680, 590)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false

# ---------- 8. 任务列表 ----------
$lblTasks = New-Object System.Windows.Forms.Label
$lblTasks.Text = "点击任务（圆圈就是位置，按顺序执行，延时支持区间如 1~3）："
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

# ---------- 9. 任务操作按钮 ----------
function Add-TaskRow([int]$x, [int]$y) {
    $idx = $dgv.Rows.Add($x, $y, "左键", "单击", 1.0, 0)
    $dgv.CurrentCell = $dgv.Rows[$idx].Cells["colX"]
}

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = "添加任务"
$btnAdd.Location = New-Object System.Drawing.Point(12, 286)
$btnAdd.Size = New-Object System.Drawing.Size(90, 30)
$btnAdd.Add_Click({
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    Add-TaskRow ($vs.X + $vs.Width / 2) ($vs.Y + $vs.Height / 2)
    $lblStatus.Text = "已添加任务：拖动屏幕上的圈到目标位置"
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
})

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

# ---------- 10. 运行设置区 ----------
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

# ---------- 11. 预设方案区 ----------
$lblPreset = New-Object System.Windows.Forms.Label
$lblPreset.Text = "预设方案："
$lblPreset.Location = New-Object System.Drawing.Point(12, 374)
$lblPreset.Size = New-Object System.Drawing.Size(62, 25)

$cmbPreset = New-Object System.Windows.Forms.ComboBox
$cmbPreset.Location = New-Object System.Drawing.Point(74, 371)
$cmbPreset.Size = New-Object System.Drawing.Size(170, 25)
$cmbPreset.DropDownStyle = "DropDownList"

$btnSavePreset = New-Object System.Windows.Forms.Button
$btnSavePreset.Text = "保存 (F12)"
$btnSavePreset.Location = New-Object System.Drawing.Point(252, 371)
$btnSavePreset.Size = New-Object System.Drawing.Size(90, 30)

$btnNewPreset = New-Object System.Windows.Forms.Button
$btnNewPreset.Text = "新建"
$btnNewPreset.Location = New-Object System.Drawing.Point(347, 371)
$btnNewPreset.Size = New-Object System.Drawing.Size(60, 30)

$btnDelPreset = New-Object System.Windows.Forms.Button
$btnDelPreset.Text = "删除"
$btnDelPreset.Location = New-Object System.Drawing.Point(412, 371)
$btnDelPreset.Size = New-Object System.Drawing.Size(60, 30)

$form.Controls.Add($lblPreset)
$form.Controls.Add($cmbPreset)
$form.Controls.Add($btnSavePreset)
$form.Controls.Add($btnNewPreset)
$form.Controls.Add($btnDelPreset)

# ---------- 12. 提示 + 状态栏 + 开始按钮 ----------
$lblHotkey = New-Object System.Windows.Forms.Label
$lblHotkey.Text = "热键：F9 开始/停止 · F10 拾取位置 · F11 添加任务 · F12 保存当前预设"
$lblHotkey.Location = New-Object System.Drawing.Point(12, 412)
$lblHotkey.Size = New-Object System.Drawing.Size(620, 25)
$lblHotkey.ForeColor = [System.Drawing.Color]::DarkBlue

$lblCircle = New-Object System.Windows.Forms.Label
$lblCircle.Text = "点击圈：拖动改坐标 · 右键圈删除该任务 · 运行中当前点高亮"
$lblCircle.Location = New-Object System.Drawing.Point(12, 438)
$lblCircle.Size = New-Object System.Drawing.Size(620, 25)
$lblCircle.ForeColor = [System.Drawing.Color]::DarkOrange

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "就绪：下拉框选预设即加载 · 添加任务后按 F9 开始"
$lblStatus.Location = New-Object System.Drawing.Point(12, 468)
$lblStatus.Size = New-Object System.Drawing.Size(620, 25)
$lblStatus.ForeColor = [System.Drawing.Color]::Gray

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "开始  (F9)"
$btnStart.Location = New-Object System.Drawing.Point(12, 505)
$btnStart.Size = New-Object System.Drawing.Size(150, 45)

$form.Controls.Add($lblHotkey)
$form.Controls.Add($lblCircle)
$form.Controls.Add($lblStatus)
$form.Controls.Add($btnStart)

# ---------- 13. 可视化圈层：创建覆盖层 + 回调绑定 ----------
$script:overlay = $null
$script:overlayReady = $false

# 拖圈结束 -> 更新表格对应行
[CircleOverlay]::OnMoved = [System.Action[int,int,int]]{ param($i, $x, $y)
    $list = @()
    foreach ($r in $dgv.Rows) { if (-not $r.IsNewRow) { $list += $r } }
    if ($i -lt $list.Count) {
        $list[$i].Cells["colX"].Value = $x
        $list[$i].Cells["colY"].Value = $y
        $lblStatus.Text = "任务 $($i+1) 已移动到 ($x, $y)"
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
    }
}

# 右键圈 -> 删除该任务
[CircleOverlay]::OnRight = [System.Action[int]]{ param($i)
    $list = @()
    foreach ($r in $dgv.Rows) { if (-not $r.IsNewRow) { $list += $r } }
    if ($i -lt $list.Count) {
        $dgv.Rows.Remove($list[$i])
        $lblStatus.Text = "已删除任务 $($i+1)"
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
    }
}

# 根据表格内容刷新覆盖层上的圈
function Refresh-Overlay {
    if (-not $script:overlayReady -or $null -eq $script:overlay) { return }
    $pts = New-Object System.Collections.Generic.List[System.Drawing.PointF]
    foreach ($r in $dgv.Rows) {
        if ($r.IsNewRow) { continue }
        $x = 0; $y = 0
        if ([int]::TryParse([string]$r.Cells["colX"].Value, [ref]$x) -and
            [int]::TryParse([string]$r.Cells["colY"].Value, [ref]$y)) {
            $pts.Add((New-Object System.Drawing.PointF($x, $y)))
        }
    }
    [CircleOverlay]::Pts = $pts.ToArray()
    $script:overlay.Invalidate()
}

# 高亮更新（运行中当前点击点）
function Update-OverlayHighlight {
    if (-not $script:overlayReady -or $null -eq $script:overlay) { return }
    $cur = -1
    if ($script:running -and $script:phase -eq "run") { $cur = $script:curRow }
    if ([CircleOverlay]::Current -ne $cur) {
        [CircleOverlay]::Current = $cur
        $script:overlay.Invalidate()
    }
}

# 表格变化 -> 刷新圈
$dgv.Add_CellValueChanged({ Refresh-Overlay })
$dgv.Add_RowsAdded({ Refresh-Overlay })
$dgv.Add_RowsRemoved({ Refresh-Overlay })

$script:overlayReady = $true

# ---------- 14. 配置读写（供自动保存 / 预设共用） ----------
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

# ---------- 15. 预设管理 ----------
function Refresh-PresetList {
    $cmbPreset.Items.Clear()
    if (Test-Path $script:presetDir) {
        Get-ChildItem $script:presetDir -Filter "*.json" | ForEach-Object { $cmbPreset.Items.Add($_.BaseName) | Out-Null }
    }
}

function Save-Preset {
    if ($null -eq $cmbPreset.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("请先在列表中选择要保存到的预设，或用「新建」创建一个", "提示")
        return
    }
    $name = [string]$cmbPreset.SelectedItem
    if (-not (Test-Path $script:presetDir)) { New-Item -ItemType Directory -Path $script:presetDir -Force | Out-Null }
    Save-CfgToFile (Join-Path $script:presetDir ($name + ".json"))
    $lblStatus.Text = "已保存到预设「$name」"
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
}

function New-Preset {
    $name = [Microsoft.VisualBasic.Interaction]::InputBox("请输入新预设名称：", "新建预设", "预设" + (Get-Random -Minimum 1 -Maximum 999))
    $name = $name.Trim()
    if (-not $name) { return }
    if (-not (Test-Path $script:presetDir)) { New-Item -ItemType Directory -Path $script:presetDir -Force | Out-Null }
    $path = Join-Path $script:presetDir ($name + ".json")
    if (Test-Path $path) {
        $r = [System.Windows.Forms.MessageBox]::Show("预设「$name」已存在，要覆盖吗？", "确认",
             [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    Save-CfgToFile $path
    $script:presetGuard = $true
    Refresh-PresetList | Out-Null
    $cmbPreset.SelectedItem = $name
    $script:presetGuard = $false
    $lblStatus.Text = "已新建预设「$name」，F12 可随时保存到它"
    $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
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
        Refresh-PresetList | Out-Null
        $lblStatus.Text = "已删除预设「$name」"
        $lblStatus.ForeColor = [System.Drawing.Color]::Gray
    }
}

$script:presetGuard = $false
$cmbPreset.Add_SelectedIndexChanged({
    if ($script:presetGuard -or $null -eq $cmbPreset.SelectedItem) { return }
    $name = [string]$cmbPreset.SelectedItem
    if (Load-CfgFromFile (Join-Path $script:presetDir ($name + ".json"))) {
        $lblStatus.Text = "已加载预设「$name」"
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $lblStatus.Text = "预设「$name」读取失败"
        $lblStatus.ForeColor = [System.Drawing.Color]::Red
    }
})

$btnSavePreset.Add_Click({ Save-Preset })
$btnNewPreset.Add_Click({ New-Preset })
$btnDelPreset.Add_Click({ Delete-Preset })

# ---------- 16. 运行状态机 ----------
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
        Update-OverlayHighlight
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
        Update-OverlayHighlight
        return
    }

    # ---- 执行阶段 ----
    if ($script:waitMs -gt 0) {
        $script:waitMs -= 100
        if ($script:waitMs -lt 0) { $script:waitMs = 0 }
        Update-OverlayHighlight
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
    Update-OverlayHighlight
})

# ---------- 17. 开始 / 停止 ----------
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
    $btnSavePreset.Enabled = $false; $btnNewPreset.Enabled = $false
    $btnDelPreset.Enabled = $false
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

    # 锁定覆盖层：运行中圈完全点击穿透（点击直达目标），禁止拖动/删除
    [CircleOverlay]::Locked = $true
    Refresh-Overlay | Out-Null

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
    $btnSavePreset.Enabled = $true; $btnNewPreset.Enabled = $true
    $btnDelPreset.Enabled = $true
    $cmbPreset.Enabled = $true
    $btnStart.Text = "开始  (F9)"
    $lblStatus.Text = "已停止（共 $($script:doneRounds) 轮、$($script:totalClicks) 次点击）"
    $lblStatus.ForeColor = [System.Drawing.Color]::Gray

    # 解锁覆盖层：圈恢复可拖动/右键
    [CircleOverlay]::Locked = $false
    [CircleOverlay]::Current = -1
    Refresh-Overlay | Out-Null
}

$btnStart.Add_Click({
    if ($script:running) { Stop-Clicker } else { Start-Clicker }
})

# ---------- 18. 全局热键 F9~F12 ----------
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
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        Add-TaskRow ($vs.X + $vs.Width / 2) ($vs.Y + $vs.Height / 2)
        $lblStatus.Text = "已添加任务：拖动屏幕上的圈到目标位置"
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
    }

    # F12：保存预设
    if ([MouseSim]::WasKeyPressed(0x7B)) {
        Save-Preset
    }
})
$hotkeyTimer.Start()

# 覆盖层 z-order 维持（TopMost 组件竞争时保持圈在最上，不抢焦点）
$zTimer = New-Object System.Windows.Forms.Timer
$zTimer.Interval = 500
$zTimer.Add_Tick({
    if ($script:overlayReady -and $null -ne $script:overlay) {
        try { $script:overlay.BringToFront() } catch {}
    }
})
$zTimer.Start()

# ---------- 19. 关闭时自动保存配置 ----------
$form.Add_FormClosing({
    $hotkeyTimer.Stop()
    $zTimer.Stop()
    if ($script:running) { Stop-Clicker }
    if ($script:overlayReady -and $null -ne $script:overlay) { $script:overlay.Close() }
    Save-CfgToFile $script:cfgPath
    [System.Environment]::Exit(0)
})

# ---------- 20. 启动 ----------
try {

    $script:overlay = New-Object CircleOverlay
    $script:overlay.Show()

    Refresh-PresetList | Out-Null
    $null = Load-CfgFromFile $script:cfgPath
    Refresh-Overlay | Out-Null

    $isAdmin = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        $lblStatus.Text = "就绪（普通权限；若点不了管理员窗口/游戏，右键->以管理员身份运行）"
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
    }

    # 注意：ShowDialog() 模态会禁用覆盖层（圈拖不动/点不穿）；
    #       Application.Run 在 ps2exe 环境会异常。用非模态 Show + DoEvents 消息泵。
    $form.Show()

    while (-not $form.IsDisposed) {

        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
} catch {
    try { $_ | Out-String | Set-Content (Join-Path $script:appDir "error.log") -Encoding UTF8 } catch {}
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "启动错误") | Out-Null
}
