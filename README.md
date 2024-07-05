# rmail-server

A [PeterOS](https://github.com/Platratio34/peterOS) [pgm-get](https://github.com/peterOS-pgm-get/pgm-get) program

Install on PeterOS via:
```console
pgm-get install rmail-server
```

## Command

### `rmail-server`: Start rMail server

## Appdata

Path: `%appdata%/rmail-server/`

Log: `/home/.pgmLog/rmail-server.log`

### Config File

`%appdata%/rmail-server/cfg.json`

``` json
{
    "db": {
        "url": "[Database URL]",
        "name": "[DB name]",
        "user": "[DB User Name]",
        "password": "[DB User Password]"
    },
    "hostname": "[Server Hostname]"
}
```