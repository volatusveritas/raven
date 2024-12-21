function raven.commands.release()
    raven.run 'odin build raven -out:build/raven_release.exe -o:speed -disable-assert -no-bounds-check'
end

function raven.commands.build()
    raven.run 'odin build raven -out:build/raven.exe -o:none'
end

function raven.commands.debug()
    raven.run 'odin build raven -out:build/raven_db.exe -o:none -debug'
end

function raven.commands.check()
    raven.run 'odin check raven -vet-cast -vet-semicolon -vet-shadowing -vet-style -vet-unused -vet-unused-imports -vet-unused-variables -vet-using-param -vet-using-stmt -warnings-as-errors -strict-style'
end
