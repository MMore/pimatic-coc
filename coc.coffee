
module.exports = (env) ->

  convict   = env.require "convict"
  Promise   = env.require 'bluebird'
  assert    = env.require 'cassert'
  execSync  = require 'execSync'

  # Require the [SerialPort] (https://github.com/voodootikigod/node-serialport)
  {SerialPort} = require 'serialport'

  _ = env.require 'lodash'

  # the plugin class
  class COCPlugin extends env.plugins.Plugin

    @transport

    init: (app, @framework, config) ->
      env.logger.info "coc: init"

      serialName = config.serialDeviceName
      env.logger.info("coc: init with serial device name #{serialName}@#{config.baudrate}, hardwareType #{config.hardwareType}")
      
      if config.hardwareType is "COC"
        env.logger.info("running cocinit.sh")
        execSync.run("sh ./node_modules/pimatic-coc/cocinit.sh")

      @cmdReceivers = [];
      @transport = new COCTransport serialName, config.baudrate, @receiveCommandCallback

      deviceConfigDef = require("./coc-device-config-schema")

      deviceClasses = [ 
        COCSwitch,
        COCSwitchFS20
      ]

      for Cl in deviceClasses
        do (Cl) =>
          @framework.deviceManager.registerDeviceClass(Cl.name, {
            configDef: deviceConfigDef[Cl.name]
            createCallback: (deviceConfig) =>
              device = new Cl(deviceConfig)
              if Cl in [COCSwitchFS20]
                @cmdReceivers.push device
              return device
          })


    sendCommand: (id, cmdString) ->
        @transport.sendCommand id, cmdString

    receiveCommandCallback: (cmdString) =>
      for cmdReceiver in @cmdReceivers
        handled = cmdReceiver.handleReceivedCmd cmdString
        break if handled

      if (!handled)
        env.logger.info "received unhandled command string: #{cmdString}"


  # COCTransport handles the communication with the coc module
  class COCTransport

    @serial

    constructor: (serialPortName, baudrate, @receiveCommandHandler) ->

      @cmdString = ""
      @serial = new SerialPort serialPortName, baudrate: baudrate, false

      @serial.open (err) ->
        if ( err? )
          env.logger.info "open serialPort #{serialPortName} failed #{err}"
        else
          env.logger.info "open serialPort #{serialPortName}"


      @serial.on 'open', =>
        # enable receive mode of coc
        @serial.write('X01\n')

      @serial.on 'error', (err) ->
         env.logger.error "coc: serial error #{err}"

      @serial.on 'data', (data) =>
        env.logger.debug "coc: serial data received #{data}"
        dataString = "#{data}"

        # remove carriage return
        dataString = dataString.replace(/[\r]/g, '');

        # line feed ?
        if dataString.indexOf('\n') != -1
          parts = dataString.split '\n'
          @cmdString = @cmdString + parts[0]
          @receiveCommandHandler @cmdString
          if ( parts.length > 0 )
            @cmdString = parts[1]
          else
            @cmdString = ''
        else
          @cmdString = @cmdString + dataString

    sendCommand: (id, cmdString) ->
      env.logger.debug "COCTransport: #{id} sendCommand #{cmdString}"
      @serial.write(cmdString+'\n')


  # COCSwitch is a generic switch which works with on/off command strings
  class COCSwitch extends env.devices.PowerSwitch

    constructor: (@config) ->
      @id = config.id
      @name = config.name
      @commandOn = config.commandOn
      @commandOff= config.commandOff
      super()


    changeStateTo: (state) ->
      if @_state is state then return Promise.resolve true
      else return Promise.try( =>
        if state is on then cocPlugin.sendCommand @id, @commandOn else cocPlugin.sendCommand @id, @commandOff
        @_setState state
      )


  # COCSwitchFS20 controls FS20 devices
  class COCSwitchFS20 extends env.devices.PowerSwitch

    constructor: (@config) ->
      @id = config.id
      @name = config.name
      @houseid = config.houseid
      @deviceid = config.deviceid
      super()


    changeStateTo: (state) ->
      if @_state is state then return Promise.resolve true
      else return Promise.try( =>
        cmd = 'F'+@houseid+@deviceid
        if state is on
            cmd = cmd + @config.commandOn
        else
            cmd = cmd + @config.commandOff
        cocPlugin.sendCommand @id, cmd
        @_setState state
      )

    handleReceivedCmd: (command) ->
      len = command.length;
      return false if len < 9

      cmdid = command.substr(0,1)
      return false if cmdid != "F";
      
      houseid   = command.substr(1,4);
      deviceid  = command.substr(5,2);
      return false if houseid != @houseid or deviceid != @deviceid
      
      cmd = command.substr(7, len-7);
      if (cmd == @config.commandOn)
        @changeStateTo on
      else if (cmd == @config.commandOff)
        @changeStateTo off

      return true


  cocPlugin = new COCPlugin()
  return cocPlugin
