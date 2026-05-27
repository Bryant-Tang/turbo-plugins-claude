using System.Web.Mvc;

namespace HelloApp.Controllers
{
    // 中文註解:HelloController 是 turbo-plugin Phase 1 fixture 用的最小 MVC controller
    public class HelloController : Controller
    {
        // GET: /Hello/Get
        public string Get()
        {
            return "你好,turbo-plugin";
        }
    }
}
