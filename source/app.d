import std.algorithm;
import std.algorithm.comparison;
import std.algorithm.mutation;
import std.algorithm.searching;
import std.array;
import std.container.dlist;
import std.container.rbtree;
import std.file;
import std.getopt;
import std.json;
import std.net.curl;
import std.process;
import std.range;
import std.range.primitives;
import std.stdio;
import std.typecons;

immutable aur_prefix = "https://aur.archlinux.org";
immutable search_prefix = aur_prefix ~ "/rpc/?v=5&type=search";
immutable info_prefix = aur_prefix ~ "/rpc/v5/info";

immutable print_format_string = "%-*.*s %-*.*s %s";

/*
 * General use flow:
 * search for package
 * - get package info to ensure it is the right one
 * - download package and dependencies
 * - build and install dependencies, build and install package
 *
 * ./aursv2 search pkgname
 * ./aursv2 info pkgname
 * ./aursv2 download --deps pkgname
 * ...?
 */

alias SubComDef = Tuple!(void function(string[]), "func", string, "description");

int main(string[] args)
{
  SubComDef[string] subs = [
    "search": SubComDef(&subSearch, "Search for a package by name."),
    "info": SubComDef(&subInfo, "Look up a specific package and get information."),
    "download": SubComDef(&subDownload, "Download a package tar file."),
    "dlall": SubComDef(&subDownloadAll, "Download a package and dependencies.")
  ];

  if (args.length < 2 || args[1] !in subs)
  {
    stderr.writefln("usage: %s [subcommand]", args[0]);
    foreach (key ; subs.keys)
    {
      stderr.writefln("   %10s  %s", key, subs[key].description);
    }
    return 1;
  }
  else
  {
    subs[args[1]].func(args[2..$]);
    return 0;
  }
}

void subSearch(string[] args)
{
  searchPackage(args[0]);
}

/**
 * Subcommand - get info on a package
 */
void subInfo(string[] args)
{
  auto pkgObj = getPackageInfo(args[0]);
  auto resultsObj = pkgObj["results"].array[0];
  foreach (item ; ["Name", "Version", "Description", "Maintainer", "URL", "URLPath", "Submitter"])
  {
    if (item in resultsObj)
      writefln("%-11s : %s", item, resultsObj[item].str);
  }
  if ("Depends" in resultsObj && resultsObj["Depends"].array.length > 0)
  {
    writefln("%-11s : %s", "Depends", resultsObj["Depends"].array[0].str);
    foreach (dep ; resultsObj["Depends"].array[1..$])
    {
      writefln("%-11s   %s", "", dep.str);
    }
  }
  else
  {
    writefln("%-11s :", "Depends");
  }
  if ("License" in resultsObj && resultsObj["License"].array.length > 0)
  {
    writefln("%-11s : %s", "License", resultsObj["License"].array[0].str);
    foreach (lic ; resultsObj["License"].array[1..$])
    {
      writefln("%-11s   %s", "", lic.str);
    }
  }
  else
  {
    writefln("%-11s :", "License");
  }
  foreach (item ; ["NumVotes"])
  {
    if (item in resultsObj)
      writefln("%-11s : %s", item, resultsObj[item].integer);
    else
      writefln("%-11s :", item);
  }
  foreach (item ; ["Popularity"])
  {
    if (item in resultsObj)
      writefln("%-11s : %f", item, resultsObj[item].floating);
    else
      writefln("%-11s :", item);
  }
}

void subDownload(string[] args)
{
  downloadPackage(args[0]);
}

void subDownloadAll(string[] args)
{
  downloadWithDependencies(args[0..$]);
}

auto lookupPackageName(string pkgname)
{
  string search_url = search_prefix ~ "&arg=" ~ pkgname;
  auto search_result = get(search_url);
  return parseJSON(search_result);
}

auto getPackageInfo(string pkgname)
{
  string info_url = info_prefix ~ "/" ~ pkgname;
  auto info_result = get(info_url);
  return parseJSON(info_result);
}

auto getPackageInfo(T)(T pkglist)
  if (isInputRange!T)
{
  string args_list = "?arg[]=" ~ join(pkglist, "&arg[]=");
  string info_url = info_prefix ~ args_list;
  auto info_result = get(info_url);
  return parseJSON(info_result);
}

void searchPackage(string pkgname)
{
  auto bundle = lookupPackageName(pkgname);
  auto goods = bundle["results"].array.filter!(r => r["OutOfDate"].isNull).array;
  if (goods.length == 0)
  {
    writeln("No results found.");
  }
  else {
    ulong nameLen = getFieldMaxLen(goods, "Name");
    ulong maintLen = getFieldMaxLen(goods, "Maintainer");
    stderr.writefln("Found %d packages.", goods.length);
    writefln(print_format_string, nameLen, nameLen, "Package", maintLen, maintLen, "Maintainer", "Description");
    foreach(r; goods)
    {
      string maint = r.tryGetField("Maintainer");
      string desc = r.tryGetField("Description");
      writefln(print_format_string, nameLen, nameLen, r["Name"].str, maintLen, maintLen, maint, desc);
    }
  }
}

ulong getFieldMaxLen(JSONValue[] searchable, string field)
{
  return max(5, searchable.filter!(s => !s[field].isNull).map!(s => s[field].str.length).maxElement);
}

string tryGetField(T)(T result, string fieldName)
{
  if (result[fieldName].isNull)
  {
    return "None";
  }
  else
  {
    return result[fieldName].str;
  }
}

auto getDependencies(string pkgname)
{
  auto infoObj = getPackageInfo(pkgname);
  foreach (dep ; infoObj["results"].array[0]["Depends"].array)
  {
    writeln(dep.str);
  }
}

void downloadPackage(string pkgname)
{
  auto infoObj = getPackageInfo(pkgname);
  auto goods = infoObj["results"].array.filter!(r => r["Name"].str == pkgname).array;
  if (goods.length > 0)
  {
    writefln("Downloading package %s.", pkgname);
    downloadAndUntar(goods[0]);
  }
  else
  {
    stderr.writefln("Error: package %s not found.", pkgname);
  }
}

bool downloadAndUntar(JSONValue pkgInfo)
{
  auto filename = pkgInfo["URLPath"].str.split('/')[$-1];
  download(aur_prefix ~ pkgInfo["URLPath"].str, filename);
  auto result = escapeShellCommand("tar", "-xaf", filename).executeShell();
  if (result.status != 0)
  {
    stderr.writefln("Error unpacking %s.", filename);
    return false;
  }
  remove(filename);
  return true;
}

void downloadWithDependencies(string[] pkgnames)
{
  try
  {
    auto depQueue = DList!string();
    auto pacTree = redBlackTree!string([]);
    string[] aurDeps;
    depQueue.insert(pkgnames);
    auto seenPkgs = redBlackTree(pkgnames);

    while (!depQueue.empty)
    {
      pacTree.insert(depQueue.opSlice());
      auto infoObj = getPackageInfo(depQueue.opSlice());
      depQueue.clear();
      foreach (depObj ; infoObj["results"].array)
      {
        string curName = depObj["Name"].str;
        stderr.writefln("Processing package %s.", curName);
        aurDeps ~= curName;
        //writefln("Downloading package %s.", curName);
        downloadAndUntar(depObj);
        if ("Depends" in depObj)
          foreach (name ; depObj["Depends"].array)
          {
            if (seenPkgs.insert(name.str) > 0)
            {
              depQueue.insertBack(name.str.split('>')[0].split('=')[0]);
            }
          }
        if ("MakeDepends" in depObj)
          foreach (name ; depObj["MakeDepends"].array)
          {
            if (seenPkgs.insert(name.str) > 0)
            {
              depQueue.insertBack(name.str.split('>')[0].split('=')[0]);
            }
          }
      }
    }

    stderr.writeln("Done with packages.");

    /* Now we output a script to deal with all of this. The goal is to have
     * this output only appear when a flag is provided, but that is TBD.
     */

    // Get a list of items to be installed through Pacman; need to call array() to circumvent lazy analysis
    auto pacDeps = pacTree.opSlice().filter!(a => !canFind(aurDeps, a))().array();

    // Only reason length would not be zero is if the user specified only
    // packages unavailable through AUR.
    if (aurDeps.length > 0)
    {
      // Only install things that were not specified by the user as dependencies
      aurDeps = aurDeps.filter!(a => !canFind(pkgnames, a))().array();

      if (pacDeps.length > 0)
      {
        // Download dependencies needed for packages and build
        writefln("sudo pacman -S --asdeps --needed %s", join(pacDeps, ' '));
      }

      // Output shell commands to build everything - this is for the user to perform, not us
      // These shell commands were written for ZSH compatibility, particularly for the PKGS array
      writeln("BD=\"${PWD}\"");
      if (aurDeps.length > 0)
      {
        // Any dependencies on AUR are handled here, so that they are installed as dependencies through --asdeps flag
        writefln("for dep in %s", join(aurDeps.reverse, ' '));
        writeln("do; echo ${dep}; cd ${dep}; makepkg -i --asdeps; cd \"${BD}\"; done");
      }
      // Now handle the main event, installing as explicit
      writeln("unset PKGS; set -a PKGS");
      writefln("for pkg in %s", join(pkgnames, ' '));
      writeln("do; echo ${pkg}; cd ${pkg}; makepkg; PKGS+=(${(f)\"$(makepkg --packagelist)\"}); cd \"${BD}\"; done");
      writeln("sudo pacman -U ${PKGS}");
      if (pacDeps.length > 0)
      {
        // Remove unneeded dependencies
        writeln("sudo pacman -Rns $(pacman -Qtdq)");
      }
    }
    else
    {
      writeln("echo Package not found.");
    }
  }
  catch(Error)
  {
    writeln("echo Error received, no action.");
  }
}
