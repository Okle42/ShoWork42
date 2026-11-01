using ShoWork;
using Xunit;

namespace ShoWork.Tests;

/// TermSend 的純邏輯：換行處理、按鍵事件、找目標、能不能送。真的打字（AttachConsole＋WriteConsoleInput）要在 Windows 桌面上實測。
public class TermSendTests
{
    [Fact]
    public void NewlinesBecomeSpacesLikeMacSendBack()
    {
        Assert.Equal("第一行 第二行 第三行", TermSend.Normalize("  第一行\r\n第二行\n第三行\r"));
        Assert.Equal("", TermSend.Normalize(null));
        Assert.Equal("/clear", TermSend.Normalize("/clear\n"));
    }

    [Fact]
    public void KeysAreOneDownUpPairPerUtf16UnitWithTheCharInUnicodeChar()
    {
        var k = TermSend.Keys("你好a");
        Assert.Equal(6, k.Count);
        Assert.Equal(new TermSend.Key(true, 0, 0, '你'), k[0]);
        Assert.Equal(new TermSend.Key(false, 0, 0, '你'), k[1]);
        Assert.Equal('a', k[5].Ch);
        // emoji 是代理對：兩個 UTF-16 單位照順序送，主控台那邊會自己組回來
        var e = TermSend.Keys("😀");
        Assert.Equal(4, e.Count);
        Assert.True(char.IsHighSurrogate(e[0].Ch));
        Assert.True(char.IsLowSurrogate(e[2].Ch));
    }

    [Fact]
    public void ClaudeThatUpdatedItselfMidSessionIsStillClaude()
    {
        Assert.True(TermSend.IsClaudeName("claude"));
        Assert.True(TermSend.IsClaudeName("Claude"));
        Assert.True(TermSend.IsClaudeName("claude.exe.old.1793554277148"));      // 11-02 Surface：自動更新把跑著的那支改名
        Assert.False(TermSend.IsClaudeName("claudette"));
        Assert.False(TermSend.IsClaudeName("node"));
    }

    [Fact]
    public void EnterIsARealReturnKey()
    {
        Assert.All(TermSend.EnterKeys, x => { Assert.Equal(0x0D, x.Vk); Assert.Equal('\r', x.Ch); });
        Assert.True(TermSend.EnterKeys[0].Down);
        Assert.False(TermSend.EnterKeys[1].Down);
    }

    [Fact]
    public void NamedKeysForMenus()
    {
        var down = TermSend.NamedKeys("down");
        Assert.Equal(2, down.Length);
        Assert.Equal(0x28, down[0].Vk);
        Assert.Equal('\0', down[0].Ch);                 // 方向鍵沒有字，只有 VK
        Assert.Equal(TermSend.EnterKeys, TermSend.NamedKeys("enter"));
        Assert.False(TermSend.Named.ContainsKey("ctrl+c"));   // 不提供會中斷／殺掉 session 的組合鍵
    }

    [Fact]
    public void SlashCommandsAreTypedSlowly()
    {
        Assert.True(TermSend.TypeSlowly("/clear"));
        Assert.False(TermSend.TypeSlowly("你好，這是測試"));
    }

    [Fact]
    public void Base64RoundTripsChinese()
    {
        var s = "你好，這是測試 /clear 😀";
        Assert.Equal(s, TermSend.Decode(TermSend.Encode(s)));
    }

    static readonly SessionRecord[] Sessions =
    {
        new() { Pid = 101, SessionId = "c17f0fbe-f1e3-42ac-8609-efff65ca8a4b" },
        new() { Pid = 202, SessionId = "c17f0fbe-0000-0000-0000-000000000000" },
        new() { Pid = 303, SessionId = "9a8b7c6d-1111-2222-3333-444444444444" },
    };

    [Fact]
    public void FindsByPidFullIdOrUniquePrefix()
    {
        Assert.Equal(202, TermSend.Find("202", Sessions)?.Pid);
        Assert.Equal(101, TermSend.Find("C17F0FBE-F1E3-42AC-8609-EFFF65CA8A4B", Sessions)?.Pid);
        Assert.Equal(303, TermSend.Find("9a8b7c6d", Sessions)?.Pid);
        Assert.Null(TermSend.Find("c17f0fbe", Sessions));          // 前 8 碼撞兩個：寧可不送也不送錯
        Assert.Null(TermSend.Find("9a8b", Sessions));              // 太短不認
        Assert.Null(TermSend.Find("999", Sessions));
    }

    [Theory]
    [InlineData("idle", null, true)]
    [InlineData("idle", WorkState.Done, true)]
    [InlineData("idle", WorkState.Idle, true)]
    [InlineData(null, null, true)]                    // 舊版沒有 status：看光暈
    [InlineData("busy", null, false)]
    [InlineData("waiting", null, false)]
    [InlineData("idle", WorkState.Working, false)]
    [InlineData("idle", WorkState.Input, false)]      // 對話框開著：打字會變成對話框的答案
    [InlineData(null, WorkState.Working, false)]
    public void ReadyFollowsStatusAndGlow(string? status, WorkState? glow, bool ok)
    {
        Assert.Equal(ok, TermSend.Ready(status, glow, keyIdleSec: 999, minKeyIdleSec: 0, out var why));
        Assert.False(string.IsNullOrEmpty(why));
    }

    [Fact]
    public void KeyboardIdleOnlyMattersWhenAsked()
    {
        Assert.True(TermSend.Ready("idle", null, keyIdleSec: 1, minKeyIdleSec: 0, out _));
        Assert.False(TermSend.Ready("idle", null, keyIdleSec: 1, minKeyIdleSec: 5, out var why));
        Assert.Contains("打字", why);
        Assert.True(TermSend.Ready("idle", null, keyIdleSec: 6, minKeyIdleSec: 5, out _));
    }
}
