SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
/*
Copyright (c) 2010, Chun-I Caber Chu
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met: 

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer. 
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution. 

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

The views and conclusions contained in the software and documentation are those
of the authors and should not be interpreted as representing official policies, 
either expressed or implied, of the FreeBSD Project.
*/
-- =============================================
-- Version: 1.0
-- Description: Adds a one-time running monitor job
-- =============================================
/*
Usage example: 
DECLARE	@jobNameToMonitor NVARCHAR(128) = 'myJobName'
	,	@databaseName VARCHAR(128) = 'myDatabaseName'
	,	@maxRunTime INT = 1
	,	@emailMsg NVARCHAR(2000) = 'My customized email message'
	,	@emailTo NVARCHAR(500) = 'test@test.com'
	;
EXEC dbo.[spUtility_addJobMonitor] @jobNameToMonitor, @databaseName, @maxRunTime, @emailMsg, @emailTo;
EXEC dbo.spUtility_addJobMonitor '_BuildCourseSummaryJobTest', 'DENG0313', 1, 'My customized email message.', 'test@test.com';
*/
CREATE PROCEDURE [dbo].[spUtility_addJobMonitor]
	@jobNameToMonitor NVARCHAR(128)
,	@databaseName  VARCHAR(128)
,	@maxRunTime       INT = 30 -- minutes from the time you called this sproc
,	@emailMsg         NVARCHAR(2000) = NULL
,	@emailTo          NVARCHAR(500) = NULL	-- Send email using a separate script located on the server if specified.
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE	@tmpMsg            NVARCHAR(MAX),
			@jobName           NVARCHAR(128),
			@description       NVARCHAR(256),
			@command           NVARCHAR(MAX),
			@nextRunTime       DATETIME,
			@scheduleStartDate CHAR(8),
			@scheduleStartTime CHAR(6),
			@jobId             BINARY(16),
			@schedule_id       INT,
			@categoryName      NVARCHAR(100) = N'[Uncategorized (Local)]'
			;
	
	-- Set default @emailTo if you want
	IF @emailTo IS NULL BEGIN
		SET @emailTo = '';
	END

	SET @nextRunTime = DATEADD(N, @maxRunTime, GETDATE());
	-- PRINT 'Scheduled: ' + CAST(@nextRunTime AS VARCHAR);

	SET @scheduleStartDate = CAST(DATEPART(YYYY, @nextRunTime) AS VARCHAR)
		+ RIGHT('00' + CAST(DATEPART(M, @nextRunTime) AS VARCHAR), 2)
		+ RIGHT('00' + CAST(DATEPART(D, @nextRunTime) AS VARCHAR), 2)
		;
	
	SET @scheduleStartTime = RIGHT('00' + DATEPART(HH, @nextRunTime), 2)
		+ RIGHT('00' + CAST(DATEPART(N, @nextRunTime) AS VARCHAR), 2)
		+ RIGHT('00' + CAST(DATEPART(SS, @nextRunTime) AS VARCHAR), 2)
		;

	-- PRINT @scheduleStartDate;
	-- PRINT @scheduleStartTime;
	/********************************************************************************************/
	BEGIN TRANSACTION
		DECLARE @returnCode INT = 0;

		IF NOT EXISTS (SELECT name FROM MSDB.DBO.syscategories WHERE name = N'[Uncategorized (Local)]' AND category_class = 1) BEGIN
			EXEC @ReturnCode = MSDB.DBO.SP_ADD_CATEGORY
				@class = N'JOB',
				@type = N'LOCAL',
				@name = @categoryName
				;
				
			IF (@@ERROR <> 0 OR @returnCode <> 0) GOTO QUITWITHROLLBACK;
		END

		SET @jobName = N'Monitor_' + @jobNameToMonitor;
		SET @description = N'Monitors ' + @jobNameToMonitor;

		-- Before adding a job, make sure one with the same name (or the previous created one) doesn't already exist.
		IF EXISTS (SELECT 1 FROM MSDB.DBO.sysjobs_view WHERE name = @jobName) BEGIN
			EXEC MSDB..SP_DELETE_JOB @job_name = @jobName;
        END;

		/***** Add a job *****/
		EXEC @returnCode = MSDB.DBO.SP_ADD_JOB
			@job_name=@jobName,
			@enabled=1,
			@notify_level_eventlog=0,
			@notify_level_email=0,
			@notify_level_netsend=0,
			@notify_level_page=0,
			@delete_level=3,--deletes the job after it completes
			@description=@description,
			@category_name=@categoryName,
			@owner_login_name=N'sa',
			@job_id = @jobId OUTPUT
			;

		IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QUITWITHROLLBACK;

		/****** Step [Start Monitoring] ******/
		-- Sets the command to run for the scheduled monitor
		SET @command = N'EXEC dbo.spUtility_isSQLJobStillRunning '
			+ '''' + @jobNameToMonitor + ''', '
			+ CAST(@maxRunTime AS VARCHAR)
			+ ';'
			;

		EXEC @ReturnCode = MSDB.DBO.SP_ADD_JOBSTEP
			@job_id=@jobId,
			@step_name=N'Start Monitoring',
			@step_id=1,
			@cmdexec_success_code=0,
			@on_success_action=1,
			@on_success_step_id=0,
			--@on_fail_action=4,
			--@on_fail_step_id=0,
			--2,
			@retry_attempts=0,
			@retry_interval=0,
			@os_run_priority=0,
			@subsystem=N'TSQL',
			@command=@command,
			@database_name=@databaseName,
			@flags=4
			;

		IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QUITWITHROLLBACK;
		
		/****** Step [Step 2. Failure Notification]  This step should be customized for each individual server. ******/
		IF @emailMsg IS NULL BEGIN
			SET @emailMsg = 'Alert: ' + @@SERVERNAME + ' Job ' + @jobNameToMonitor + ' exceeded expected run time of ' + CAST(@maxRunTime AS VARCHAR) + ' minutes';
		END

		IF NOT ISNULL(RTRIM(@emailTo), '') = '' BEGIN -- If email is provided
			SET @command = N'cscript g:\sendmailutility.vbs primaryEmailAddress@test.com "'
				+ @emailTo
				+ '" "Job Run Time Alert: '
				+ @jobNameToMonitor
				+ ' > ' + CAST(@maxRunTime AS VARCHAR) + ' minutes" "' + @emailMsg + '"'
				;
		END
		ELSE BEGIN  -- Email not provided
			SET @command = '-- No command specified.';
		END;

		EXEC @returnCode = MSDB.DBO.SP_ADD_JOBSTEP
			@job_id=@jobId,
			@step_name=N'Step 2. Failure Notification',
			@step_id=2,
			@cmdexec_success_code=0,
			@on_success_action=1,
			@on_success_step_id=0,
			@on_fail_action=2,
			@on_fail_step_id=0,
			@retry_attempts=0,
			@retry_interval=0,
			@os_run_priority=0,
			@subsystem=N'CmdExec',
			@command=@command,
			@flags=0
			;

		IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QUITWITHROLLBACK;


		EXEC @returnCode = MSDB.DBO.SP_UPDATE_JOBSTEP
			@job_id = @jobId,
			@step_id = 1,
			@on_fail_action=4,
			@on_fail_step_id=2
			;
		IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QUITWITHROLLBACK;

		EXEC @returnCode = MSDB.DBO.SP_UPDATE_JOB
			@job_id = @jobId,
			@start_step_id = 1
			;
		IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QUITWITHROLLBACK;

		EXEC @ReturnCode = MSDB.DBO.SP_ADD_JOBSERVER
			@job_id = @jobId,
			@server_name = N'(local)'
			;
		IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QUITWITHROLLBACK;

		-- Add one-time schedule
		EXEC MSDB.DBO.SP_ADD_JOBSCHEDULE
			--@job_id=N'7ca8a871-8d1d-431a-870a-ce7a9c615858',
			@job_id=@jobId,
			--@job_name=@jobName,
			@name=N'JobMonitorSchedule',
			@enabled=1,
			@freq_type=1,
			@freq_interval=1,
			@freq_subday_type=0,
			@freq_subday_interval=0,
			@freq_relative_interval=0,
			@freq_recurrence_factor=1,
			@active_start_date=@scheduleStartDate,
			@active_end_date=99991231,
			@active_start_time=@scheduleStartTime,
			@active_end_time=235959,
			@schedule_id = @schedule_id OUTPUT
			;

		-- PRINT @schedule_id
		IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QUITWITHROLLBACK;

	COMMIT TRANSACTION

	GOTO ENDSAVE;

	QUITWITHROLLBACK:
		IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION;

	ENDSAVE:
	/********************************************************************************************/
END