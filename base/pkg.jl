require("git")
require("pkgmetadata")

module Pkg
#
# Julia's git-based declarative package manager
#

using Metadata

import Git

# default locations: local package repo, remote metadata repo

const DEFAULT_META = "git://github.com/JuliaLang/METADATA.jl.git"

# some utility functions

function cd_pkgdir(f::Function)
    dir = julia_pkgdir()
    if !isdir(dir)
        error("Package directory $dir doesn't exist; run Pkg.init() to create it.")
    end
    cd(f,dir)
end

# create a new empty packge repository

function init(meta::String)
    dir = julia_pkgdir()
    if isdir(dir)
        error("Package directory $dir already exists.")
    end
    try
        run(`mkdir -p $dir`)
        cd(dir) do
            # create & configure
            run(`git init`)
            run(`git commit --allow-empty -m "Initial empty commit"`)
            run(`git remote add origin .`)
            if success(`git config --global github.user` > "/dev/null")
                base = basename(dir)
                user = readchomp(`git config --global github.user`)
                run(`git config remote.origin.url git@github.com:$user/$base`)
            else
                run(`git config --unset remote.origin.url`)
            end
            run(`git config branch.master.remote origin`)
            run(`git config branch.master.merge refs/heads/master`)
            # initial content
            run(`touch REQUIRE`)
            run(`git add REQUIRE`)
            run(`git submodule add $meta METADATA`)
            run(`git commit -m "Empty package repo"`)
            cd(Git.autoconfig_pushurl,"METADATA")
            Metadata.gen_hashes()
        end
    catch
        run(`rm -rf $dir`)
    end
end
init() = init(DEFAULT_META)

# get/set the origin url for package repo

origin() = cd_pkgdir() do
    try readchomp(`git config remote.origin.url`)
    catch
        return nothing
    end
end
origin(url::String) = cd_pkgdir() do
    run(`git config remote.origin.url $url`)
end

# add and remove packages by name

add(pkgs::Vector{VersionSet}) = cd_pkgdir() do
    for pkg in pkgs
        if !contains(Metadata.packages(),pkg.package)
            error("Unknown package $(pkg.package); Perhaps you need to Pkg.update() for new metadata?")
        end
        reqs = parse_requires("REQUIRE")
        if anyp(req->req.package==pkg.package,reqs)
            error("package already required: $pkg")
        end
        open("REQUIRE","a") do io
            print(io,pkg.package)
            for ver in pkg.versions
                print(io,"\t$ver")
            end
            println(io)
        end
    end
    run(`git add REQUIRE`)
    _resolve()
end
function add(pkgs::Union(String,VersionSet)...)
    pkgs_ = VersionSet[]
    for pkg in pkgs
        Base.push(pkgs_, isa(pkg,VersionSet) ? pkg : VersionSet(pkg))
    end
    add(pkgs_)
end

rm(pkgs::Vector{String}) = cd_pkgdir() do
    for pkg in pkgs
        if !contains(Metadata.packages(),pkg)
            error("invalid package: $pkg")
        end
        reqs = parse_requires("REQUIRE")
        if !anyp(req->req.package==pkg,reqs)
            error("package not required: $pkg")
        end
        open("REQUIRE") do r
            open("REQUIRE.new","w") do w
                for line in each_line(r)
                    fields = split(line)
                    if isempty(fields) || fields[1]!=pkg
                        print(w,line)
                    end
                end
            end
        end
        run(`mv REQUIRE.new REQUIRE`)
    end
    run(`git add REQUIRE`)
    _resolve()
end
rm(pkgs::String...) = rm(String[pkgs...])

# list available, required & installed packages

available() = cd_pkgdir() do
    [Metadata.each_package()...]
end

required() = cd_pkgdir() do
    parse_requires("REQUIRE")
end

installed() = cd_pkgdir() do
    h = Dict{String,Union(VersionNumber,String)}()
    Git.each_submodule(false) do name, path, sha1
        if name != "METADATA"
            h[name] = Metadata.version(name,sha1)
        end
    end
    return h
end

# update packages from requirements

function _resolve()
    have = (String=>ASCIIString)[]
    reqs = parse_requires("REQUIRE")
    Git.each_submodule(false) do pkg, path, sha1
        if pkg != "METADATA"
            have[pkg] = sha1
            if cd(Git.attached,path) && isfile("$path/REQUIRE")
                append!(reqs,parse_requires("$path/REQUIRE"))
                if isfile("$path/VERSION")
                    ver = convert(VersionNumber,readchomp("$path/VERSION"))
                    Base.push(reqs,VersionSet(pkg,[ver]))
                end
            end
        end
    end
    sort!(reqs)
    want = Metadata.resolve(reqs)
    pkgs = sort!(keys(merge(want,have)))
    for pkg in pkgs
        if has(have,pkg)
            managed = cd(pkg) do
                !Git.dirty() && !Git.attached()
            end
            if !managed continue end
            if has(want,pkg)
                if have[pkg] != want[pkg]
                    oldver = Metadata.version(pkg,have[pkg])
                    newver = Metadata.version(pkg,want[pkg])
                    up = oldver <= newver ? "Up" : "Down"
                    println("$(up)grading $pkg: v$oldver => v$newver")
                    cd(pkg) do
                        run(`git checkout -q $(want[pkg])`)
                    end
                    run(`git add -- $pkg`)
                end
            else
                ver = Metadata.version(pkg,have[pkg])
                println("Removing $pkg v$ver")
                run(`git rm -qrf --cached -- $pkg`)
                Git.modules(`--remove-section submodule.$pkg`)
                run(`git add .gitmodules`)
                run(`rm -rf -- $pkg`)
            end
        else
            ver = Metadata.version(pkg,want[pkg])
            println("Installing $pkg: v$ver")
            if ispath(pkg)
                # TODO: maybe if this is a git repo or submodule, just take it over?
                error("Path $pkg already exists! Please remove to allow installation.")
            end
            url = Metadata.pkg_url(pkg)
            run(`git submodule add --reference . $url $pkg`)
            cd(pkg) do
                try run(`git checkout -q $(want[pkg])` .> "/dev/null")
                catch
                    run(`git fetch -q`)
                    try run(`git checkout -q $(want[pkg])`)
                    catch
                        error("An invalid SHA1 hash seems to be registered for $pkg. Please contact the package maintainer.")
                    end
                end
                Git.autoconfig_pushurl()
            end
            run(`git add -- $pkg`)
        end
    end
end
resolve() = cd(_resolve,julia_pkgdir())

# clone a new package repo from a URL

# TODO: this is horribly broken
function clone(url::String)
    dir = julia_pkgdir()
    if isdir(dir)
        error("Package directory $dir already exists.")
    end
    tmpdir = mktempdir()
    run(`git clone $url $tmpdir`)
    cd(tmpdir) do
        gitdir = abs_path(readchomp(`git rev-parse --git-dir`))
        Git.each_submodule(false) do name, path, sha1
            cd(path) do
                run(`git fetch-pack $gitdir $sha1`)
            end
        end
    end
    run(`mv $tmpdir $dir`)
end

# record all submodule commits as tags

function tag_submodules()
    Git.each_submodule(true) do name, path, sha1
        run(`git fetch-pack -q $path HEAD`)
        run(`git tag -f submodules/$path/$(sha1[1:10]) $sha1`)
        run(`git --git-dir=$path/.git gc -q`)
    end
end

# checkout a particular repo version

checkout(rev::String) = cd_pkgdir() do
    run(`git checkout -fq $rev -- REQUIRE`)
    _resolve()
end
checkout() = checkout("HEAD")

# commit the current state of the repo with the given message

assert_git_clean() = Git.dirty() &&
    error("The following contents must be committed:\n",
          readall(`git ls-files -d -m -s -u`))

function commit(msg::String)
    tag_submodules()
    Git.canonicalize_config(".gitmodules")
    run(`git add .gitmodules`)
    run(`git commit -m $msg`)
end

function commit(f::Function, msg::String)
    assert_git_clean()
    try f()
    catch
        print(stderr_stream,
              "\n\n*** ERROR ENCOUNTERED ***\n\n",
              "Rolling back to HEAD...\n")
        checkout()
        rethrow()
    end
    if Git.staged() && !Git.unstaged()
        commit(msg)
        run(`git diff --name-only --diff-filter=D HEAD^ HEAD` | `xargs rm -rf`)
        checkout()
    elseif !Git.dirty()
        println(stderr_stream, "Nothing to commit.")
    else
        error("There are both staged and unstaged changes to packages.")
    end
end

# set package remote in METADATA

pkg_origin(pkg::String, remote::String) = cd_pkgdir() do
    for line in each_line(`git --git-dir=$(file_path(pkg,".git")) remote -v`)
        m = match(r"^(\S*)\s*(\S*)\s*\(fetch\)", line)
        if m != nothing && m.captures[1] == remote
            cd(file_path("METADATA", pkg)) do
                open("url", "w") do io
                    println(io, m.captures[2])
                end
            end
            return
        end
    end
end
pkg_origin(pkg) = pkg_origin(pkg, "origin")

# push & pull package repos to/from remotes

push() = cd_pkgdir() do
    assert_git_clean()
    tag_submodules()
    run(`git push --tags`)
    run(`git push`)
end

pull() = cd_pkgdir() do
    assert_git_clean()

    # get remote data
    run(`git fetch --tags`)
    run(`git fetch`)

    # see how far git gets with merging
    if success(`git merge -m "[jul] pull (simple merge)" FETCH_HEAD`) return end

    # get info about local, remote and base trees
    L = readchomp(`git rev-parse --verify HEAD`)
    R = readchomp(`git rev-parse --verify FETCH_HEAD`)
    B = readchomp(`git merge-base $L $R`)
    Rc = Git.read_config_blob("$R:.gitmodules")
    Rs = Git.config_sections(Rc)

    # intelligently 3-way merge .gitmodules versions
    if Git.different(L,R,".gitmodules")
        Bc = Git.read_config_blob("$B:.gitmodules")
        Lc = Git.read_config_blob("$L:.gitmodules")
        Cc, conflicts, deleted = Git.merge_configs(Bc,Lc,Rc)
        # warn about config conflicts
        for (key,vals) in conflicts
            print(stderr_stream,
                "\nModules config conflict for $key:\n",
                "  local value  = $(vals[1])\n",
                "  remote value = $(vals[2])\n",
                "\n",
                "Both values written to .gitmodules -- please edit and choose one.\n\n",
            )
            Cc[key] = vals
        end
        # remove submodules that were deleted
        for section in deleted
            if !begins_with(section,"submodule.") continue end
            path = get(Lc,"$section.path",nothing)
            if path == nothing continue end
            run(`git rm -qrf --cached --ignore-unmatch -- $path`)
            run(`rm -rf $path`)
        end
        # write the result (unconditionally) and stage it (if no conflicts)
        Git.write_config(".gitmodules", Cc)
        if isempty(conflicts) run(`git add .gitmodules`) end
    end

    # merge submodules
    Git.each_submodule(false) do name, path, sha1
        if has(Rs,"submodule.$name") && Git.different(L,R,path)
            alt = readchomp(`git rev-parse $R:$path`)
            cd(path) do
                run(`git merge --no-edit $alt`)
            end
            run(`git add -- $path`)
        end
    end

    # check for remaining merge conflicts
    if Git.unstaged()
        unmerged = readall(`git ls-files -m` | `sort` | `uniq`)
        unmerged = replace(unmerged, r"^", "    ")
        print(stderr_stream,
            "\n\n*** WARNING ***\n\n",
            "You have unresolved merge conflicts in the following files:\n\n",
            unmerged,
            "\nPlease resolve these conflicts, `git add` the files, and commit.\n"
        )
        error("pull: merge conflicts")
    end

    # try to commit -- fails if unresolved conflicts remain
    run(`git commit -m "[jul] pull (complex merge)"`)
    checkout("HEAD")
    tag_submodules()
end

# update system to latest and greatest

update() = cd_pkgdir() do
    cd("METADATA") do
        run(`git pull`)
    end
    Metadata.gen_hashes()
    run(`git add METADATA`)
    # TODO: handle package deletions
    Git.each_submodule(false) do pkg, path, sha1
        url = Metadata.pkg_url(pkg)
        if url != nothing
            Git.modules(`submodule.$pkg.url $url`)
            cd(path) do
                if !Git.dirty()
                    if Git.attached()
                        run(ignorestatus(`git pull --ff-only`))
                    else
                        run(`git config remote.origin.url $url`)
                        run(`git fetch -q`)
                    end
                end
            end
        end
    end
    run(`git add .gitmodules`)
    run(`git submodule sync -q`)
    _resolve()
end

latest_version(pkg::String) = cd_pkgdir() do
    vers = VersionNumber[]
    for (ver, _) in Metadata.each_tagged_version(pkg)
        Base.push(vers, ver)
    end
    max(vers)
end

version(pkg::String, ver::VersionNumber) = cd_pkgdir() do
    if any(pkg .== Metadata.packages())
        if ver != v"0.0.0" && ver <= latest_version(pkg)
            error("The latest version of package $(pkg) is $(string(ver)). You must specify a later version.")
        end
    else
        if !isdir(file_path("METADATA", pkg))
            mkdir(file_path("METADATA", pkg))
        end
    end
    sha1 = ""
    cd(pkg) do
        sha1 = readchomp(`git rev-parse HEAD`)
        if ver > v"0.0.0"
            run(`git tag $(string(ver)) HEAD`)
        end
    end
    cd(file_path("METADATA", pkg)) do
        if !isdir("hashes") mkdir("hashes") end
        if !isdir("versions") mkdir("versions") end
        cd("versions") do
            if !isdir(string(ver)) mkdir(string(ver)) end
            open(file_path(string(ver), "sha1"), "w") do io
                println(io, sha1)
            end
        end
    end
    file_copy(
        file_path(pkg, "REQUIRE"),
        file_path("METADATA", pkg, "versions", string(ver), "requires"))
    Metadata.gen_hashes(pkg)
end

function patch(pkg)
    lver = latest_version(pkg)
    if lver > v"0.0.0"
        version(pkg, VersionNumber(lver.major, lver.minor, lver.patch+1))
    else
        version(pkg, v"0.0.0")
    end
end
function minor(pkg)
    lver = latest_version(pkg)
    version(pkg, VersionNumber(lver.major, lver.minor+1))
end
function major(pkg)
    lver = latest_version(pkg)
    version(pkg, VersionNumber(lver.major+1))
end

# Create a skeleton package that can be easily filled in
function new(package_name::String)
    cd_pkgdir() do
        try
            mkdir(package_name)
        catch
            error("Unable to create directory for new package: $(package_name)")
        end
        try
            sha1 = ""
            cd(package_name) do
                run(`git init`)
                run(`git commit --allow-empty -m "Initial empty commit"`)
                file_create("LICENSE.md") # Should insert MIT content
                file_create("README.md")
                file_create("REQUIRE")
                mkdir("src")
                file_create(file_path("src", strcat(package_name, ".jl")))
                mkdir("test")
                run(`git add --all`)
                run(`git commit -m "Scaffold for Julia package $(package_name)"`)
                sha1 = readchomp(`git rev-parse HEAD`)
            end
            version(package_name, v"0.0.0")
        catch
            error("Unable to initialize contents of new package")
        end
        newpath = file_path(julia_pkgdir(), package_name)
        println(
"
You have created a new package in

  $(file_path(julia_pkgdir(), package_name))

When the package is ready to submit, push it to a public repository, set it as
the remote \"origin\", then run:

  > Pkg.set_origin($(package_name))
  > Pkg.patch($(package_name))

to prepare METADATA with the details for your package."
                )
    end
end

# Remove local traces of a package (broken due to a bad .new(), for instance)
obliterate(package_name::String) = cd_pkgdir() do
    run(`rm -rf $(package_name) $(file_path("METADATA", package_name))`)
end

# If a package contains data, make it easy to find its location
function package_directory(package_name::String)
  if has(ENV, "JULIA_PKGDIR")
    return file_path(ENV["JULIA_PKGDIR"], package_name)
  else
    return path_expand(file_path("~/.julia", package_name))
  end
end

end # module
