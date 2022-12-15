using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.FileProviders;
using System;
using System.Buffers;
using System.Collections.Concurrent;
using System.Drawing;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace MemoryLeak.Controllers
{
    [Route("api")]
    [ApiController]
    public class ApiController : ControllerBase
    {
        public ApiController()
        {
            Interlocked.Increment(ref DiagnosticsController.Requests);
        }

        private static ConcurrentBag<string> _staticStrings = new ConcurrentBag<string>();

        [HttpGet("addstring/{size=100}")]
        public ActionResult<string> AddStaticString(int size)
        {
            var bigString = new String('x', size * 1024);
            _staticStrings.Add(bigString);
            
            return size + " * 1024 times x added";
        }

        [HttpGet("reset")]
        public string ClearStaticStrings()
        {
            _staticStrings = new ConcurrentBag<string>();

            return "memory resetted";
        }
    }
}
