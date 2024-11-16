function raven.commands.release()
    raven.run({'odin', 'build', 'raven', '-out:build/raven_release.exe', '-o:speed', '-disable-assert', '-no-bounds-check'})
end

function raven.commands.build()
    raven.run({'odin', 'build', 'raven', '-out:build/raven.exe', '-o:none'})
end

function raven.commands.debug()
    raven.run({'odin', 'build', 'raven', '-out:build/raven_db.exe', '-o:none', '-debug'})
end
