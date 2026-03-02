import cocotb
from cocotb.triggers import RisingEdge, Timer, First

@cocotb.test()
async def verilog_selftest(dut):
    # Wait for tb_done, but time out if it never happens
    done = RisingEdge(dut.tb_done)
    timeout = Timer(20, unit="ms")  # plenty for CI

    trig = await First(done, timeout)
    if trig is timeout:
        raise cocotb.result.TestFailure("Timeout waiting for tb_done")

    if int(dut.tb_fail.value) != 0:
        raise cocotb.result.TestFailure("Verilog self-test reported FAIL")
