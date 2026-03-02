import cocotb
from cocotb.triggers import Timer, RisingEdge

@cocotb.test()
async def verilog_selftest(dut):
    # Wait until tb_done goes high, with a timeout
    timeout_ns = 50_000_000  # 50 ms sim timeout (adjust if using long gate)
    waited = 0

    # Poll tb_done every 100 us
    while int(dut.tb_done.value) == 0:
        await Timer(100_000, units="ns")
        waited += 100_000
        if waited >= timeout_ns:
            raise cocotb.result.TestFailure("Timeout waiting for tb_done")

    # Check tb_fail
    if int(dut.tb_fail.value) != 0:
        raise cocotb.result.TestFailure("Verilog self-test reported FAIL")
