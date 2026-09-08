using System;
using System.Collections.Generic;
using System.Linq;
namespace XDVPN {
 public static class RouteAudit {
  sealed class R {
   public ulong Start,End; public int Bits,Index,Metric; public string Hop; public bool Local;
   public R(string value) {
    var p=value.Split('|'); var cidr=p[0].Split('/'); Bits=int.Parse(cidr[1]);
    var size=1UL << (32-Bits); Start=Number(cidr[0])/size*size; End=Start+size-1;
    if(p.Length>1) { Index=int.Parse(p[1]); Hop=p[2]; Metric=int.Parse(p[3]); Local=p[4]=="Local"; }
   }
   public bool Has(ulong p) { return Start<=p && p<=End; }
  }
  static ulong Number(string value) { var b=System.Net.IPAddress.Parse(value).GetAddressBytes(); return ((ulong)b[0]<<24)|((ulong)b[1]<<16)|((ulong)b[2]<<8)|b[3]; }
  static string Address(ulong v) { return string.Format("{0}.{1}.{2}.{3}",v>>24,(v>>16)&255,(v>>8)&255,v&255); }
  public static string[] Check(string[] rows,string[] includes,string[] excludes,string[] dns,string gateway,int tun,int physical,string hop,bool full,int[] localInterfaces) {
   var routes=rows.Select(v=>new R(v)).ToArray(); var inc=includes.Select(v=>new R(v)).ToArray(); var exc=excludes.Select(v=>new R(v)).ToArray();
   var dnsIPs=new HashSet<ulong>(dns.Select(Number)); ulong server=Number(gateway);
   var points=new SortedSet<ulong>();
   foreach(var r in routes.Concat(inc).Concat(exc)) { points.Add(r.Start); if(r.End<UInt32.MaxValue) points.Add(r.End+1); }
   foreach(var p in dnsIPs.Concat(new[]{server,Number("1.0.0.0"),Number("127.0.0.0"),Number("128.0.0.0"),Number("169.254.0.0"),Number("169.255.0.0"),Number("224.0.0.0")})) { points.Add(p); if(p<UInt32.MaxValue) points.Add(p+1); }
   foreach(var p in points) {
    bool bypass=p==server || exc.Any(r=>r.Has(p)); bool isDns=dnsIPs.Contains(p);
    if(!bypass && !isDns && !inc.Any(r=>r.Has(p))) continue;
    // Loopback, multicast and link-local are not Internet destinations.
    if(!bypass && !isDns && (p>>24==0 || p>>24==127 || p>>24>=224 || p>>16==0xA9FE)) continue;
    var choices=routes.Where(r=>r.Has(p)).OrderByDescending(r=>r.Bits).ThenBy(r=>r.Metric).ToArray();
    if(choices.Length==0) return new[]{Address(p),"none","none"};
    var selected=choices[0]; int index=bypass?physical:tun; string next=bypass?hop:"0.0.0.0";
    // A /1 full tunnel intentionally preserves directly attached LAN routes.
    bool local=full && !bypass && !isDns && selected.Local && selected.Hop=="0.0.0.0" && Array.IndexOf(localInterfaces,selected.Index)>=0 && selected.Bits>1 && !inc.Any(r=>r.Has(p) && r.Bits>1);
    if(!local && (selected.Index!=index || selected.Hop!=next)) return new[]{Address(p),selected.Index.ToString(),selected.Hop};
    if(choices.Any(r=>r.Bits==selected.Bits && r.Metric==selected.Metric && (r.Index!=selected.Index || r.Hop!=selected.Hop)))
     return new[]{Address(p),"ambiguous","ambiguous"};
   }
   return new string[0];
  }
 }
}
