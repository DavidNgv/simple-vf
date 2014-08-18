# vsfw.run [host,] [port,] [{options},] root_function
# Takes a function and runs it as a vsfw app. Optionally accepts a port
# number, and/or a hostname (any order). The hostname must be a string, and
# the port number must be castable as a number.

vsfw = version: '0.0.1'

vsfw.title = 'vSoft'
vsfw.codename = 'You can\'t do that on stage anymore'



# All variables declaration
log = console.log
fs = require 'fs'
path = require 'path'
uuid = require 'node-uuid'
uglify = require 'uglify-js'
methods = require 'methods'


# Express must first be called after we modify the `fs` module.
express = require 'express'
socketio = require 'socket.io'





# Takes in a function and builds express/socket.io apps based on the rules
# contained in it.
vsfw.app = ->
  for a in arguments
    switch typeof a
      when 'function'
        func = a
      when 'object'
        options = a

  options ?= {}

  context = {id: uuid.v4(), vsfw, express}

  real_root = path.dirname(module.parent.filename)
  root =  path.join real_root, ".vsfw-#{context.id}"

  # Storage for user-provided stuff.
  # Views are kept at the module level.
  ws_handlers = {}
  helpers = {}
  postrenders = {}
  partials = {}

  app = context.app = express()
  if options.https?
    context.server = require('https').createServer options.https, app
  else
    context.server = require('http').createServer app
  if options.disable_io
    io = null
  else
    io = context.io = socketio.listen context.server, options.io ? {}

  # Reference to the vsfw client, the value will be set later.
  client = null
  client_bundled = null
  client_bundle_simple = null

  # Tracks if the vsfw middleware is already mounted (`@use 'vsfw'`).
  vsfw_used = no

  # vsfw's default settings.
  app.set 'view engine', 'coffee'
  app.engine 'coffee', coffeecup_adapter

  # Sets default view dir to @root
  app.set 'views', path.join(root, '/views')

  # Location of vsfw-specific URIs.
  app.set 'vsfw_prefix', '/vsfw'

  for verb in [methods...,'del','all']
    do (verb) ->
      context[verb] = (args...) ->
        arity = args.length
        if arity > 1
          route
            verb: verb
            path: args[0]
            middleware: flatten args[1...arity-1]
            handler: args[arity-1]
        else
          for k, v of arguments[0]
            # Apply middleware if value is array
            if v instanceof Array
              route
                verb: verb
                path: k
                middleware: flatten v[0...v.length-1]
                handler: v[v.length-1]

            else
              route verb: verb, path: k, handler: v
        return

  context.helper = (obj) ->
    for k, v of obj
      helpers[k] = v
    return

  context.on = (obj) ->
    for k, v of obj
      ws_handlers[k] = v
    return

  context.view = (obj) ->
    for k, v of obj
      ext = path.extname k
      p = path.join app.get('views'), k
      # I'm not even sure this is needed -- Express doesn't ask for it
      vsfw_fs[p] = v
      if not ext
        ext = '.' + app.get 'view engine'
        vsfw_fs[p+ext] = v
    return

  context.engine = (obj) ->
    for k, v of obj
      app.engine k, v
    return

  context.set = (obj) ->
    for k, v of obj
      app.set k, v
    return

  context.enable = ->
    app.enable i for i in arguments
    return

  context.disable = ->
    app.disable i for i in arguments
    return

  wrap_middleware = (f) ->
    (req,res,next) ->
      ctx =
        app: app
        settings: app.settings
        locals: res.locals
        request: req
        req: req
        query: req.query
        params: req.params
        body: req.body
        session: req.session
        response: res
        res: res
        next: next

      apply_helpers ctx

      if app.settings['databag']
        ctx.data = {}
        copy_data_to ctx.data, [req.query, req.params, req.body]

      f.call ctx, req, res, next

  context.middleware = (f) ->
    # If magic middleware is enabled the function will get wrapped
    # by the caller; do not double-wrap it.
    if app.settings['magic middleware']
      f
    else
      wrap_middleware f

  use_middleware = (f) ->
    if app.settings['magic middleware']
      wrap_middleware f
    else
      f

  context.use = ->
    vsfw_middleware =
    # Connect `static` middlewate uses fs.stat().
      static: (options) ->
        if typeof options is 'string'
          options = path: options
        options ?= {}
        p = options.path ? path.join(real_root, '/public')
        delete options.path
        express.static(p,options)
      vsfw: ->
        vsfw_used = yes
        (req, res, next) ->
          send = (code) ->
            res.contentType 'js'
            res.send code
          if req.method.toUpperCase() isnt 'GET' then next()
          else
            vsfw_prefix = app.settings['vsfw_prefix']
            switch req.url
              when vsfw_prefix+'/Vsfw.js' then send client_bundled
              when vsfw_prefix+'/Vsfw-simple.js' then send client_bundle_simple
              when vsfw_prefix+'/vsfw.js' then send client
              when vsfw_prefix+'/jquery.js' then send jquery_minified
              when vsfw_prefix+'/sammy.js' then send sammy_minified
              else next()
          return
      partials: (maps = {}) ->
        express_partials ?= require 'zappa-partials'
        partials = express_partials()
        partials.register 'coffee', coffeecup_adapter.render
        for k,v of maps
          partials.register k, v
        partials
      session: (options) ->
        context.session_store = options.store
        express.session options

    use = (name, arg = null) ->
      if vsfw_middleware[name]
        app.use vsfw_middleware[name](arg)
      else if typeof express[name] is 'function'
        app.use use_middleware express[name](arg)
      else
        throw "Unknown middleware #{name}"

    for a in arguments
      switch typeof a
        when 'function' then app.use use_middleware a
        when 'string' then use a
        when 'object'
          if a.stack? or a.route? or a.handle?
            app.use a
          else
            use k, v for k, v of a
    return

  context.include = (p) ->
    sub = if typeof p is 'string' then require path.join(real_root, p) else p
    sub.include.apply context

  apply_helpers = (ctx) ->
    for name, helper of helpers
      do (name, helper) ->
        if typeof helper is 'function'
          ctx[name] = ->
            helper.apply ctx, arguments
        else
          ctx[name] = helper
        return
    ctx

  context.param = (obj) ->
    build = (callback) ->
      (req,res,next,p) ->
        ctx =
          app: app
          settings: app.settings
          locals: res.locals
          request: req
          req: req
          query: req.query
          params: req.params
          body: req.body
          session: req.session
          response: res
          res: res
          next: next
          param: p
        apply_helpers ctx
        callback.call ctx, req, res, next, p

    for k, v of obj
      @app.param k, build v

    return

  # Register a route with express.
  route = (r) ->
    r.middleware ?= []

    # Rewrite middleware
    r.middleware = r.middleware.map wrap_middleware

    if typeof r.handler is 'string'
      app[r.verb] r.path, r.middleware, (req, res) ->
        res.contentType r.contentType if r.contentType?
        res.send r.handler
        return
    else
      app[r.verb] r.path, r.middleware, (req, res, next) ->
        ctx =
          app: app
          settings: app.settings
          locals: res.locals
          request: req
          req: req
          query: req.query
          params: req.params
          body: req.body
          session: req.session
          response: res
          res: res
          next: next
          send: -> res.send.apply res, arguments
          json: -> res.json.apply res, arguments
          jsonp: -> res.jsonp.apply res, arguments
          redirect: -> res.redirect.apply res, arguments
          format: -> res.format.apply res, arguments
          render: ->
            if typeof arguments[0] isnt 'object'
              render.apply @, arguments
            else
              for k, v of arguments[0]
                render.apply @, [k, v]
            return
          emit: ->
            socket = request_socket req
            if socket?
              if typeof arguments[0] isnt 'object'
                socket.emit.apply socket, arguments
              else
                for k, v of arguments[0]
                  socket.emit.apply socket, [k, v]
            return

        render = (name,opts = {},fn) ->

          report = fn ? (err,html) ->
            if err
              next err
            else
              res.send html

          # Make sure the second arg is an object.
          if typeof opts is 'function'
            fn = opts
            opts = {}

          if app.settings['databag']
            opts.params = ctx.data

          if not opts.postrender?
            postrender = report
          else
            postrender = (err, str) ->
              if err then return report err
              # Apply postrender before sending response.
              jsdom.env html: str, src: [jquery], done: (err, window) ->
                if err then return report err
                ctx.window = window
                rendered = postrenders[opts.postrender].apply ctx, [window.$]

                doctype = (window.document.doctype or '') + "\n"
                html = doctype + window.document.documentElement.outerHTML
                report null, html
              return

          res.render.call res, name, opts, postrender

        apply_helpers ctx

        if app.settings['databag']
          ctx.data = {}
          copy_data_to ctx.data, [req.query, req.params, req.body]

        if app.settings['x-powered-by']
          res.setHeader 'X-Powered-By', "vsfw #{vsfw.version}"

        result = r.handler.call ctx, req, res, next

        res.contentType(r.contentType) if r.contentType?
        if typeof result is 'string' then res.send result
        else return result


  # Go!
  func.apply context

  # The stringified vsfw client.
  client = require('./client').build(vsfw.version, app.settings)
  client = ";#{coffeescript_helpers}(#{client})();"
  client_bundle_simple =
    if io?
      jquery + socketjs + client
    else
      jquery + client
  client_bundled =
    if io?
      jquery + socketjs + sammy + client
    else
      jquery + sammy + client

  if app.settings['minify']
    client = minify client
    client_bundle_simple = minify client_bundle_simple
    client_bundled = minify client_bundled

  if app.settings['default layout']
    context.view layout: ->
      extension = (path,ext) ->
        if path.substr(-(ext.length)).toLowerCase() is ext.toLowerCase()
          path
        else
          path + ext
      doctype 5
      html ->
        head ->
          title @title if @title
          if @scripts
            for s in @scripts
              script src: extension s, '.js'
          script(src: extension @script, '.js') if @script
          if @stylesheets
            for s in @stylesheets
              link rel: 'stylesheet', href: extension s, '.css'
          link(rel: 'stylesheet', href: extension @stylesheet, '.css') if @stylesheet
          style @style if @style
        body @body

  if io?
    vsfw_prefix = app.settings['vsfw_prefix']
    context.get vsfw_prefix+'/socket/:channel_name/:socket_id', ->
      if @session?
        channel_name = @params.channel_name
        socket_id = @params.socket_id

        @session.__socket ?= {}

        if @session.__socket[channel_name]?
          # Client (or hijacker) trying to re-key.
          @send error:'Channel already assigned', channel_name: channel_name
        else
          key = uuid.v4() # used for socket 'authorization'

          # Update the Express session store
          @session.__socket[channel_name] =
            id: socket_id
            key: key

          # Update the Socket.IO store
          io_client = io.sockets.store.client(socket_id)
          io_data = JSON.stringify
            id: @req.sessionID
            key: key
          io_client.set socketio_key, io_data

          # Let the client know which key to use.
          @send channel_name: channel_name, key: key
      else
        @send error:'No session'
      return

  context



vsfw.run = ->
  host = null
  port = 3000
  root_function = null
  options =
    disable_io: false

  for a in arguments
    switch typeof a
      when 'string'
        if isNaN( (Number) a ) then host = a
        else port = (Number) a
      when 'number' then port = a
      when 'function' then root_function = a
      when 'object'
        for k, v of a
          switch k
            when 'host' then host = v
            when 'port' then port = v
            when 'disable_io' then options.disable_io = v
            when 'https' then options.https = v

  vsapp = vsfw.app(root_function, options)
  app = vsapp.app

  express_ready = ->
    log '#{vsfw.title} server listening on port %d in %s mode',
      vsapp.server.address()?.port, app.settings.env
    log "#{vsfw.title} #{vsfw.version} \"#{vsfw.codename}\" orchestrating the show"

  if host
    vsapp.server.listen port, host, express_ready
  else
    vsapp.server.listen port, express_ready

  vsapp
