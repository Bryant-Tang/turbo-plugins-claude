namespace HelloApp.Controllers
{
    // 中文註解:HelloController 是 turbo-plugin Phase 1 fixture 用的最小 plain class。
    // 故意不繼承 System.Web.Mvc.Controller — fixture 只需驗證中文 source body byte-level
    // 通過 build / publish / pack 流程不變,不需要實際 MVC routing(避免 NuGet 依賴)。
    public class HelloController
    {
        // 中文 string literal — 給 R18 source body byte-level 測試 case 用
        public string Get()
        {
            return "你好,turbo-plugin";
        }
    }
}
