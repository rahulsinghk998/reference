// STM32 microprocessor firmware updater
// Copyright (c) 2014 Electric Imp
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT

// GLOBALS AND CONSTS ----------------------------------------------------------

const BLOCKSIZE = 4096; // bytes per buffer of data sent from agent
const STM32_SECTORSIZE = 0x4000;
const BAUD = 115200; // any standard baud between 9600 and 115200 is allowed
                    
BYTE_TIME <- 8.0 / (BAUD * 1.0);

// CLASS AND FUNCTION DEFS -----------------------------------------------------

function hexdump(data) {
    local i = 0;
    while (i < data.tell()) {
        local line = " ";
        for (local j = 0; j < 8 && i < data.tell(); j++) {
            line += format("%02x ", data[i++]);
        }
        server.log(line);
    }
}

// This class implements the UART bootloader command set
// https://github.com/electricimp/reference/tree/master/hardware/stm32/UART
class Stm32 {    
    static INIT_TIME        = 0.5; // seconds
    static UART_CONN_TIME   = 0.010; // ms, initial UART configuration time
    static TIMEOUT_CMD      = 100; // ms
    static TIMEOUT_ERASE    = 30000; // ms; erases take a long time!
    static TIMEOUT_WRITE    = 1000; // ms
    static TIMEOUT_PROTECT  = 5000; // ms; used when enabling or disabling read or write protect

    static CMD_INIT         = 0x7F;
    static ACK              = 0x79;
    static NACK             = 0x1F;
    static CMD_GET          = 0x00;
    static CMD_GET_VERSION_PROT_STATUS = 0x01;
    static CMD_GETID       = 0x02;
    static CMD_RD_MEM    = 0x11;
    static CMD_GO           = 0x21;
    static CMD_WR_MEM    = 0x31;
    static CMD_ERASE        = 0x43; // ERASE and EXT_ERASE are exclusive; only one is supported
    static CMD_EXT_ERASE    = 0x44;
    static CMD_WR_PROT      = 0x63;
    static CMD_WR_UNPROT    = 0x73;
    static CMD_RDOUT_PROT   = 0x82;
    static CMD_RDOUT_UNPROT = 0x92;
    
    static FLASH_BASE_ADDR  = 0x08000000;
    static WRSIZE = 256; // max bytes per write
    static SECTORSIZE = 0x4000; // size of one flash "page"
    

    bootloader_version = null;
    bootloader_active = false;
    supported_cmds = [];
    pid = null;
    mem_ptr = 0;
    
    uart = null;
    nrst = null;
    boot0 = null;
    boot1 = null;
    
    constructor(_uart, _nrst, _boot0, _boot1 = null) {
        uart = _uart;
        nrst = _nrst;
        boot0 = _boot0;
        if (_boot1) { boot1 = _boot1; }
        mem_ptr = FLASH_BASE_ADDR;
    }
    
    // Helper function: clear the UART RX FIFO by reading out any remaining data
    // Input: None
    // Return: None
    function clearUart() {
        local byte = uart.read();
        while (byte != -1) {
            byte = uart.read();
        }
    }
    
    // Helper function: block and read a set number of bytes from the UART
    // Times out if the UART doesn't receive the required number of bytes in 2 * BYTE TIME
    // Helpful primarily when reading more than the UART RX FIFO can hold (80 bytes)
    // Input: num_bytes (integer)
    // Return: RX'd data (blob)
    function readUart(num_bytes) {
        local result = blob(num_bytes);
        local start = hardware.millis();
        local pos = result.tell();
        local timeout = 10 * BYTE_TIME * num_bytes * 1000;
        while (result.tell() < num_bytes) {
            if (hardware.millis() - start > timeout) {
                throw format("Timed out waiting for data, got %d / %d bytes",pos,num_bytes);
            }
            local byte = uart.read();
            if (byte != -1) {
                result.writen(byte,'b');
                pos++;
            }
        }
        return result;
    }
    
    // Helper function: compute the checksum for a blob and write the checksum to the end of the blob
    // Note that STM32 checksum is really just a parity byte
    // Input: data (blob)
    //      Blob pointer should be at the end of the data to checksum
    // Return: data (blob), with checksum written to end
    function wrChecksum(data) {
        local checksum = 0;
        for (local i = 0; i < data.tell(); i++) {
            //server.log(format("%02x",data[i]));
            checksum = (checksum ^ data[i]) & 0xff;
        }
        data.writen(checksum, 'b');
    }
    
    // Helper function: send a UART bootloader command
    // Not all commands can use this helper, as some require multiple steps
    // Sends command, gets ACK, and receives number of bytes indicated by STM32
    // Input: cmd - USART bootloader command (defined above)
    // Return: response (blob) - results of sending command
    function sendCmd(cmd) {
        clearUart();
        local checksum = (~cmd) & 0xff;
        uart.write(format("%c%c",cmd,checksum));
        getAck(TIMEOUT_CMD);
        imp.sleep(BYTE_TIME * 2);
        local num_bytes = uart.read() + 0;
        if (cmd == CMD_GETID) {num_bytes++;} // getId command responds w/ number of bytes in ID - 1.
        imp.sleep(BYTE_TIME * (num_bytes + 4));
        
        local result = blob(num_bytes);
        for (local i = 0; i < num_bytes; i++) {
            result.writen(uart.read(),'b');
        }
        
        result.seek(0,'b');
        return result;
    }
    
    // Helper function: wait for an ACK from STM32 when sending a command
    // Implements a timeout and blocks until ACK is received or timeout is reached
    // Input: [optional] timeout in µs
    // Return: bool. True for ACK, False for NACK.
    function getAck(timeout) {
        local byte = uart.read();
        local start = hardware.millis();
        while ((hardware.millis() - start) < timeout) {
            // server.log(format("Looking for ACK: %02x",byte));
            if (byte == ACK) { return true; }
            if (byte == NACK) { return false; }
            if (byte != -1) { server.log(format("%02x",byte)); }
            byte = uart.read();
        }
        throw "Timed out waiting for ACK after "+timeout+" ms";
    }
    
    // set the class's internal pointer for the current address in flash
    // this allows functions outside the class to start at 0 and ignore the flash base address
    // Input: relative position of flash memory pointer (integer)
    // Return: None
    function setMemPtr(addr) {
        mem_ptr = addr + FLASH_BASE_ADDR;
    }
    
    // get the relative position of the current address in flash
    // Input: None
    // Return: relative position of flash memory pointer (integer)
    function getMemPtr() {
        return mem_ptr - FLASH_BASE_ADDR;
    }
    
    // get the base address of flash memory
    // Input: None
    // Return: flash base address (integer)
    function getFlashBaseAddr() {
        return FLASH_BASE_ADDR;
    }
    
    // Reset the STM32 to bring it out of USART bootloader
    // Releases the boot0 pin, then toggles reset
    // Input: None
    // Return: None
    function reset() {
        bootloader_active = false;
        nrst.write(0);
        // release boot0 so we don't come back up in USART bootloader mode
        boot0.write(0);
        imp.sleep(0.010);
        nrst.write(1);
    }
    
    // Reset the STM32 and bring it up in USART bootloader mode
    // Applies "pattern1" from "STM32 system memory boot mode” application note (AN2606)
    // Note that the USARTs available for bootloader vary between STM32 parts
    // Input: None
    // Return: None
    function enterBootloader() {
        // hold boot0 high, boot1 low, and toggle reset
        nrst.write(0);
        boot0.write(1);
        if (boot1) { boot1.write(0); }
        nrst.write(1);
        // bootloader will take a little time to come up
        imp.sleep(INIT_TIME);
        // release boot0 so we don't wind up back in the bootloader on our next reset
        boot0.write(0);
        // send a command to initialize the bootloader on this UART
        clearUart();
        uart.write(CMD_INIT);
        imp.sleep(UART_CONN_TIME);
        local response = uart.read() + 0;
        if (response == ACK) {
            // USART bootloader successfully configured
            bootloader_active = true;
            return;
        } else {
            throw "Failed to configure USART Bootloader, got "+response;
        }
    }
    
    // Send the GET command to the STM32
    // Gets the bootloader version and a list of supported commands
    // The imp will store the results of this command to save time if asked again later
    // Input: None
    // Return: Result (table)
    //      bootloader_version (byte)
    //      supported_cmds (array)
    function get() {
        // only request info from the device if we don't already have it
        if (bootloader_version == null || supported_cmds.len() == 0) {
            // make sure the bootloader is active; allows us to call this method directly from outside the class
            if (!bootloader_active) { enterBootloader(); }
            local result = sendCmd(CMD_GET);
            bootloader_version = result.readn('b');
            bootloader_version = format("%d.%d",((bootloader_version & 0xf0) >> 4),(bootloader_version & 0x0f)).tofloat();
            while (!result.eos()) {
                local byte  = result.readn('b');
                supported_cmds.push(byte);
            }
        } 
        return {bootloader_version = bootloader_version, supported_cmds = supported_cmds};
    }
    
    // Send the GET ID command to the STM32
    // Gets the chip ID from the device
    // The imp will store the results of this command to save time if asked again later
    // Input: None
    // Return: pid (2 bytes)
    function getId() {
        // just return the value if we already know it
        if (pid == null) {
            // make sure bootloader is active before sending command
            if (!bootloader_active) { enterBootloader(); }
            local result = sendCmd(CMD_GETID);
            pid = result.readn('w');
        }
        return format("%04x",pid);
    }
    
    // Read a section of device memory
    // Input: 
    //      addr: 4-byte address. Refer to “STM32 microcontroller system memory boot mode” application note (AN2606) for valid addresses
    //      len: number of bytes to read. 0-255.
    // Return: 
    //      memory contents from addr to addr+len (blob)
    function rdMem(addr, len) {
        if (!bootloader_active) { enterBootloader(); }
        clearUart();
        uart.write(format("%c%c",CMD_RD_MEM, (~CMD_RD_MEM) & 0xff));
        getAck(TIMEOUT_CMD);
        // read mem command ACKs, then waits for starting memory address
        local addrblob = blob(5);
        addrblob.writen(addr,'i');
        addrblob.swap4(); // STM32 wants MSB-first. Imp is LSB-first.
        wrChecksum(addrblob);
        uart.write(addrblob);
        if (!getAck(TIMEOUT_CMD)) {
            throw format("Read Failed for addr %08x (invalid address)",addr);
        };
        // STM32 ACKs the address, then waits for the number of bytes to read
        len = len & 0xff;
        uart.write(format("%c%c",len, (~len) & 0xff));
        if (!getAck(TIMEOUT_CMD)) {
            throw format("Read Failed for %d bytes starting at %08x (read protected)",len,addr);
        }
        // blocking read the memory contents
        local result = readUart(len);
        return result;
    }
    
    // Execute downloaded or other code by branching to a specified address
    // When the address is valid and the command is executed: 
    // - registers of all peripherals used by bootloader are reset to default values
    // - user application's main stack pointer is initialized
    // - STM32 jumps to memory location specified + 4
    // Host should send base address where the application to jump to is programmed
    // Jump to application only works if the user application sets the vector table correctly to point to application addr
    // Input: 
    //      addr: 4-byte address
    // Return: None
    function go(addr = null) {
        if (!bootloader_active) { enterBootloader(); }
        clearUart()
        uart.write(format("%c%c",CMD_GO, (~CMD_GO) & 0xff));
        getAck(TIMEOUT_CMD);
        // GO command ACKs, then waits for starting address
        // if no address was given, assume image starts at the beginning of the flash
        if (addr == null) { addr = FLASH_BASE_ADDR; }
        local addrblob = blob(5);
        addrblob.writen(addr,'i');
        addrblob.swap4(); // STM32 wants MSB-first. Imp is LSB-first.
        wrChecksum(addrblob);
        uart.write(addrblob);        
        if (!getAck(TIMEOUT_CMD)) {
            throw format("Write Failed for addr %08x (invalid address)",addr);
        };
        // system will now exit bootloader and jump into application code
        bootloader_active = false;
        setMemPtr(0);
    }
    
    // Write data to any valid memory address (RAM, Flash, Option Byte Area, etc.)
    // Note: to write to option byte area, address must be base address of this area
    // Maximum length of block to be written is 256 bytes
    // Input: 
    //      addr: 4-byte starting address
    //      data: data to write (0 to 256 bytes, blob)
    // Return: None
    function wrMem(data, addr = null) {
        if (!bootloader_active) { enterBootloader(); }
        if (addr == null) { addr = mem_ptr; }
        data.seek(0,'b');
    
        while (!data.eos()) {
            local bytes_left = data.len() - data.tell();
            local bytes_to_write = bytes_left > WRSIZE ? WRSIZE : bytes_left;
            local buffer = data.readblob(bytes_to_write);
            
            clearUart();
            uart.write(format("%c%c",CMD_WR_MEM, (~CMD_WR_MEM) & 0xff));
            getAck(TIMEOUT_CMD);
        
            // read mem command ACKs, then waits for starting memory address
            local addrblob = blob(5);
            addrblob.writen(mem_ptr,'i');
            addrblob.swap4(); // STM32 wants MSB-first. Imp is LSB-first.
            wrChecksum(addrblob);
            uart.write(addrblob);
            if (!getAck(TIMEOUT_CMD)) {
                throw format("Got NACK on wrMemORY for addr %08x (invalid address)",addr);
            };
            
            // STM32 ACKs the address, then waits for the number of bytes to be written
            local wrblob = blob(buffer.len() + 2);
            wrblob.writen(buffer.len() - 1,'b');
            wrblob.writeblob(buffer);
            wrChecksum(wrblob);
            uart.write(wrblob);
            
            if(!getAck(TIMEOUT_WRITE)) {
                throw "Write Failed (NACK)";
            }
            mem_ptr += bytes_to_write;
        }
    }
    
    // Erase flash memory pages
    // Note that either ERASE or EXT_ERASE are supported, but not both
    // The STM32F407VG does not support ERASE
    // Input:
    //      num_pages (1-byte integer) number of pages to erase
    //      page_codes (array)
    // Return: None
    function eraseMem(num_pages, page_codes) {
        if (!bootloader_active) { enterBootloader(); }
        setMemPtr(0);
        clearUart();
        uart.write(format("%c%c",CMD_ERASE, (~CMD_ERASE) & 0xff));
        getAck(TIMEOUT_CMD);
        local erblob = blob(page_codes.len() + 2);
        erblob.writen(num_pages & 0xff, 'b');
        foreach (page in page_codes) {
            erblob.writen(page & 0xff, 'b');
        }
        wrChecksum(erblob);
        uart.write(wrblob);
        if (!getAck(TIMEOUT_ERASE)) {
            throw "Flash Erase Failed (NACK)";
        }
    }
    
    // Erase all flash memory
    // Note that either ERASE or EXT_ERASE are supported, but not both
    // The STM32F407VG does not support ERASE
    // Input: None
    // Return: None
    function eraseGlobalMem() {
        if (!bootloader_active) { enterBootloader(); }
        setMemPtr(0);
        clearUart();
        uart.write(format("%c%c",CMD_ERASE, (~CMD_ERASE) & 0xff));
        getAck(TIMEOUT_CMD);
        uart.write("\xff\x00");
        if (!getAck(TIMEOUT_ERASE)) {
            throw "Flash Global Erase Failed (NACK)";
        }
    }
    
    // Erase flash memory pages using two byte addressing
    // Note that either ERASE or EXT_ERASE are supported, but not both
    // The STM32F407VG does not support ERASE
    // Input: 
    //      page codes (array of 2-byte integers). List of "sector codes"; leading bytes of memory address to erase.
    // Return: None
    function extEraseMem(page_codes) {
        if (!bootloader_active) { enterBootloader(); }
        setMemPtr(0)
        clearUart();
        uart.write(format("%c%c",CMD_EXT_ERASE, (~CMD_EXT_ERASE) & 0xff));
        getAck(TIMEOUT_CMD);
        // 2 bytes for num_pages, 2 bytes per page code, 1 byte for checksum
        local num_pages = page_codes.len() - 1; // device erases N + 1 pages (grumble)
        local erblob = blob((2 * num_pages) + 3);
        erblob.writen((num_pages & 0xff00) >> 8, 'b');
        erblob.writen(num_pages & 0xff, 'b');
        foreach (page in page_codes) {
            erblob.writen((page & 0xff00) >> 8, 'b');
            erblob.writen(page & 0xff, 'b');
        }
        wrChecksum(erblob);
        uart.write(erblob);
        if (!getAck(TIMEOUT_ERASE)) {
            throw "Flash Extended Erase Failed (NACK)";
        }
    }
    
    // Erase all flash memory for devices that support EXT_ERASE
    // Input: None
    // Return: None
    function massErase() {
        if (!bootloader_active) { enterBootloader(); }
        setMemPtr(0);
        clearUart();
        uart.write(format("%c%c",CMD_EXT_ERASE, (~CMD_EXT_ERASE) & 0xff));
        getAck(TIMEOUT_CMD);
        uart.write("\xff\xff\x00");
        local byte = uart.read();
        local start = hardware.millis();
        if (!getAck(TIMEOUT_ERASE)) {
            throw "Flash Mass Erase Failed (NACK)";
        }
    }
    
    // Erase bank 1 flash memory for devices that support EXT_ERASE
    // Input: None
    // Return: None
    function bank1Erase() {
        if (!bootloader_active) { enterBootloader(); }
        setMemPtr(0);
        clearUart();
        uart.write(format("%c%c",CMD_EXT_ERASE, (~CMD_EXT_ERASE) & 0xff));
        getAck(TIMEOUT_CMD);
        uart.write("\xff\xfe\x01");
        if (!getAck(TIMEOUT_ERASE)) {
            throw "Flash Bank 1 Erase Failed (NACK)";
        }
        setMemPtr(0);
    }
    
    // Erase bank 2 flash memory for devices that support EXT_ERASE
    // Input: None
    // Return: None    
    function bank2Erase() {
        if (!bootloader_active) { enterBootloader(); }
        setMemPtr(0);
        clearUart();
        uart.write(format("%c%c",CMD_EXT_ERASE, (~CMD_EXT_ERASE) & 0xff));
        getAck(TIMEOUT_CMD);
        uart.write("\xff\xfd\x02");
        if (!getAck(TIMEOUT_ERASE)) {
            throw "Flash Bank 2 Erase Failed (NACK)";
        }
    }
    
    // Enable write protection for some or all flash memory sectors
    // System reset is generated at end of command to apply the new configuration
    // Input: 
    //      num_sectors: (1-byte integer) number of sectors to protect
    //      sector_codes: (1-byte integer array) sector codes of sectors to protect
    // Return: None
    function wrProt(num_sectors, sector_codes) {
        if (!bootloader_active) { enterBootloader(); }
        clearUart();
        uart.write(format("%c%c",CMD_WR_PROT, (~CMD_WR_PROT) & 0xff));
        getAck(TIMEOUT_CMD);
        local protblob = blob(sector_codes.len() + 2);
        protblob.writen(num_sectors & 0xff, 'b');
        foreach (sector in sector_codes) {
            protblob.writen(sector & 0xff, 'b');
        }
        wrChecksum(protblob);
        uart.write(protblob);
        if (!getAck(TIMEOUT_PROTECT)) {
            throw "Write Protect Unprotect Failed (NACK)";
        }
        // system will now reset
        bootloader_active = false;
        imp.sleep(INIT_TIME);
        enterBootloader();
    }
    
    // Disable write protection of all flash memory sectors
    // System reset is generated at end of command to apply the new configuration
    // Input: None
    // Return: None
    function wrUnprot() {
        if (!bootloader_active) { enterBootloader(); }
        clearUart();
        uart.write(format("%c%c",CMD_WR_UNPROT, (~CMD_WR_UNPROT) & 0xff));
        // first ACK acknowledges command
        getAck(TIMEOUT_CMD);
        // second ACK acknowledges completion of write protect enable
        if (!getAck(TIMEOUT_PROTECT)) {
            throw "Write Unprotect Failed (NACK)"
        }
        // system will now reset
        bootloader_active = false;
        imp.sleep(INIT_TIME);
        enterBootloader();
        setMemPtr(0);
    }
    
    // Enable flash memory read protection
    // System reset is generated at end of command to apply the new configuration
    // Input: None
    // Return: None
    function rdProt() {
        if (!bootloader_active) { enterBootloader(); }
        clearUart();
        uart.write(format("%c%c",CMD_RDOUT_PROT, (~CMD_RDOUT_PROT) & 0xff));
        // first ACK acknowledges command
        getAck(TIMEOUT_CMD);
        // second ACK acknowledges completion of write protect enable
        if (!getAck(TIMEOUT_PROTECT)) {
            throw "Read Protect Failed (NACK)"
        }        
        // system will now reset
        bootloader_active = false;
        imp.sleep(SYS_RESET_WAIT);
        enterBootloader();
    }
    
    // Disable flash memory read protection
    // System reset is generated at end of command to apply the new configuration
    // Input: None
    // Return: None
    function rdUnprot() {
        if (!bootloader_active) { enterBootloader(); }
        clearUart();
        uart.write(format("%c%c",CMD_RDOUT_UNPROT, (~CMD_RDOUT_UNPROT) & 0xff));
        // first ACK acknowledges command
        getAck(TIMEOUT_CMD);
        // second ACK acknowledges completion of write protect enable
        if (!getAck(TIMEOUT_PROTECT)) {
            throw "Read Unprotect Failed (NACK)";
        }
        // system will now reset
        bootloader_active = false;
        imp.sleep(INIT_TIME);
        enterBootloader();
        setMemPtr(0);
    }
}

// AGENT CALLBACKS -------------------------------------------------------------

// Allow the agent to request that the device send its bootloader version and supported commands
agent.on("get_version", function(dummy) {
    agent.send("set_version",stm32.get());
    if (stm32.bootloader_active) { stm32.reset(); }
});

// Allow the agent to request the device's PID
agent.on("get_id", function(dummy) {
    agent.send("set_id", stm32.getId());
    if (stm32.bootloader_active) { stm32.reset(); }
});

// Allow the agent to reset the stm32 to normal operation
agent.on("reset", function(dummy) {
    stm32.reset();
});

// Allow the agent to remove readback protection from the flash
// (give this a go if flash writes and erases mysteriously give you "invalid address")
agent.on("rd_unprot", function(dummy) {
    stm32.rdUnprot();
});

// Allow the agent to remove write protection from the flash
// (try this if you're unable to write new images; removed from the write routine for speed and clarity)
agent.on("wr_unprot", function(dummy) {
    stm32.wrUnprot();
});

// Allow the agent to erase the full STM32 flash 
// Useful for device recovery if something goes wrong during testing
agent.on("erase_stm32", function(dummy) {
    server.log("Enabling Flash Erase");
    stm32.wrUnprot();
    server.log("Erasing All STM32 Flash");
    stm32.massErase();
    server.log("Resetting STM32");
    stm32.reset();
    server.log("Done");
});

// Initiate an application firmware update
agent.on("load_fw", function(len) {
    server.log(format("FW Update: %d bytes",len));
    stm32.enterBootloader();
    local page_codes = [];
    local erase_through_sector = math.ceil((len * 1.0) / STM32_SECTORSIZE);
    for (local i = 0; i <= erase_through_sector; i++) {
        page_codes.push(i);
    }
    server.log(format("FW Update: Erasing %d page(s) in Flash (%d bytes each)", erase_through_sector, STM32_SECTORSIZE));
    stm32.extEraseMem(page_codes);
    stm32.setMemPtr(0);
    server.log("FW Update: Starting Download");
    // send pull request with a dummy value
    agent.send("pull", 0);
});

// used to load new application firmware; device sends a block of data to the stm32,
// then requests another block from the agent with "pull". Agent responds with "push".
agent.on("push", function(buffer) {
    stm32.wrMem(buffer);
    // send pull request with a dummy value
    agent.send("pull", 0);
});

// agent sends this event when the device has downloaded the entire new firmware image
// the device can then reset or send the GO command to start execution
agent.on("dl_complete", function(dummy) {
    server.log("FW Update: Complete, Resetting");
    // can use the GO command to jump right into flash and run
    stm32.go();
    // Or, you can just reset the device and it'll come up and run the new application code
    //stm32.reset();
    server.log("Running");
});

// MAIN ------------------------------------------------------------------------

nrst  <- hardware.pin8;
boot0 <- hardware.pin9;
uart  <- hardware.uart6E;

nrst.configure(DIGITAL_OUT);
nrst.write(1);
boot0.configure(DIGITAL_OUT);
boot0.write(0);

uart.configure(BAUD, 8, PARITY_EVEN, 1, NO_CTSRTS);

stm32 <- Stm32(uart, nrst, boot0);

server.log("Ready");