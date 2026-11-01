namespace ShoWork.Hooks;

// 本機私人設定（Mac 版 Sources/ShoWorkCore/LocalConfig.swift 的移植，格式相同）：
// 跟這台電腦、這個人有關的名字（私人 repo、遠端主機、使用者稱呼）不寫進原始碼，放在
// %LOCALAPPDATA%\ShoWork42\local.json（不進 git）。沒有這個檔＝通用預設。測試用 SHOWORK_LOCAL_CONFIG 換路徑。每次讀檔。
//
// { "owner": "…", "headsetProjects": […], "privateDataRepos": […], "winHosts": […], "noKickoffRepos": […] }
sealed class LocalConfig
{
    public string? Owner;
    public List<string>? HeadsetProjects;
    public List<string>? PrivateDataRepos;
    public List<string>? WinHosts;
    public List<string>? NoKickoffRepos;

    public static string FilePath => HookPaths.Env("SHOWORK_LOCAL_CONFIG") ?? Path.Combine(HookPaths.Support, "local.json");

    public static LocalConfig Load(string? path = null)
    {
        var o = HookJson.ReadObject(path ?? FilePath);
        if (o == null) return new LocalConfig();
        List<string>? L(string k) => o[k] is System.Text.Json.Nodes.JsonArray ? o.Strs(k) : null;
        return new LocalConfig
        {
            Owner = o.Str("owner"), HeadsetProjects = L("headsetProjects"), PrivateDataRepos = L("privateDataRepos"),
            WinHosts = L("winHosts"), NoKickoffRepos = L("noKickoffRepos"),
        };
    }

    public static LocalConfig Current => Load();

    /// 提示詞裡的使用者稱呼
    public string OwnerName => string.IsNullOrEmpty(Owner) ? "使用者" : Owner;

    static bool Has(List<string>? list, string name) => (list ?? new()).Any(x => string.Equals(x, name, StringComparison.OrdinalIgnoreCase));
    public bool IsPrivateDataRepo(string name) => Has(PrivateDataRepos, name);

    /// cwd 在不提醒開工卡的 repo 裡（路徑任一段等於清單裡的名字；Windows 的反斜線也算分隔）
    public bool SkipsKickoff(string cwd) => cwd.Split('/', '\\').Any(p => p.Length > 0 && Has(NoKickoffRepos, p));
}
