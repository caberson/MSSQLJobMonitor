SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
/*
Copyright (c) 2011, Chun-I Caber Chu
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
-- Checks whether a SQL job is running
-- =============================================
/*
Usage example: 
DECLARE	@outputMsg NVARCHAR(MAX)=''
	,	@jobName VARCHAR(50) = 'myJobName'
	,	@maxRunTime INT = 5
	;
EXEC dbo.spUtility_isSQLJobStillRunning @jobName, @maxRunTime, @outputMsg OUTPUT;
*/
CREATE PROCEDURE [dbo].[spUtility_isSQLJobStillRunning] (
	@jobName SYSNAME = 'specifyYourJobNameHere'
,	@maxRunTime INT = 30	-- minutes
,	@msg NVARCHAR(MAX) = '' OUTPUT
)
AS
	SET NOCOUNT ON;
	SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
	
	/**
	 * Refer to http://msdn.microsoft.com/en-us/library/ms186722.aspx for more syntax info on the help sproc
	 * WAITFOR info: http://msdn.microsoft.com/en-us/library/ms187331.aspx
	 */
	
	DECLARE	@job_id UNIQUEIDENTIFIER
		,	@retVal INT
		,	@nextScheduleDate CHAR(8)
		,	@nextScheduleTime CHAR(6)
		,	@nextSchedule SMALLDATETIME
		,	@maxSchedule SMALLDATETIME
		,	@i INT
		,	@delayLength CHAR(8)
		-- Error messages and status
		,	@intSeverity INT
		,	@strReturnMessage VARCHAR(500)
		;
	
	-- Set variables for testing locally
	-- SET @jobName = 'StaticJobNameHereIfYouWantToBeLazy';
	-- SET @delayLength = '00:00:20';
	
	-- verify job name is valid
	BEGIN TRY
		EXECUTE @retVal = msdb..sp_verify_job_identifiers '@jobName', '@job_id', @jobName OUTPUT, @job_id OUTPUT;
	END TRY
	BEGIN CATCH
		SET @intSeverity = ERROR_SEVERITY();
		SET @strReturnMessage = ERROR_MESSAGE();
		-- Uncomment while debugging during the development phase
		-- RAISERROR(@strReturnMessage, @intSeverity, 1);
		SET @msg = 'Error severity (' + CAST(@intSeverity AS VARCHAR) + '): ' + @strReturnMessage;
		PRINT @msg;
		
		RETURN CASE WHEN @intSeverity BETWEEN 11 AND 19 THEN 2 ELSE 1 END;
	END CATCH
	
	/***********************************
	* Create Temp tables and variables *
	***********************************/
	CREATE TABLE #job (	
		JOB_ID UNIQUEIDENTIFIER,
		ORIGINATING_SERVER NVARCHAR(MAX),
		NAME NVARCHAR(MAX),
		[ENABLED] TINYINT,
		[DESCRIPTION] NVARCHAR(MAX),
		[START_TEP_ID] INT,
		CATEGORY NVARCHAR(MAX),
		[OWNER] NVARCHAR(100),
		NOTIFY_LEVEL_EVENTLOG INT,
		NOTIFY_LEVEL_EMAIL INT,
		NOTIFY_LEVEL_NETSEND INT,
		NOTIFY_LEVEL_PAGE INT,
		NOTIFY_EMAIL_OPERATOR NVARCHAR(MAX),
		NOTIFY_NETSEND_OPERATOR NVARCHAR(MAX),
		NOTIFY_PAGE_OPERATOR NVARCHAR(MAX),
		DELETE_LEVEL INT,
		DATE_CREATED SMALLDATETIME,
		DATE_MODIFIED SMALLDATETIME,
		VERSION_NUMBER INT,
		LAST_RUN_DATE INT,
		LAST_RUN_TIME INT,
		LAST_RUN_OUTCOME TINYINT,
		NEXT_RUN_DATE INT,
		NEXT_RUN_TIME INT,
		NEXT_RUN_SCHEDULE_ID INT,
		CURRENT_EXECUTION_STATUS TINYINT,
		CURRENT_EXECUTION_STEP NVARCHAR(MAX),
		CURRENT_RETRY_ATTEMPT INT,
		HAS_STEP INT,
		HAS_SCHEDULE TINYINT,
		HAS_TARGET TINYINT,
		[TYPE] INT
	);
	
	DECLARE @job_info TABLE (
		job_id                UNIQUEIDENTIFIER NOT NULL,
        last_run_date         INT              NOT NULL,
        last_run_time         INT              NOT NULL,
        next_run_date         INT              NOT NULL,
        next_run_time         INT              NOT NULL,
        next_run_schedule_id  INT              NOT NULL,
        requested_to_run      INT              NOT NULL, -- BOOL
        request_source        INT              NOT NULL,
        request_source_id     sysname          COLLATE database_default NULL,
        running               INT              NOT NULL, -- BOOL
        current_step          INT              NOT NULL,
        current_retry_attempt INT              NOT NULL,
        job_state             INT              NOT NULL	-- 1=Executing, 3=between retries, 4=idle
		);
		
	DECLARE @job_execution_state TABLE (
		job_id                  UNIQUEIDENTIFIER NOT NULL,
		date_started            INT              NOT NULL,
		time_started            INT              NOT NULL,
		execution_job_status    INT              NOT NULL,
		execution_step_id       INT              NULL,
		execution_step_name     sysname          COLLATE database_default NULL,
		execution_retry_attempt INT              NOT NULL,
		next_run_date           INT              NOT NULL,
		next_run_time           INT              NOT NULL,
		next_run_schedule_id    INT              NOT NULL
		);

	-- get job info
	INSERT INTO @job_info
	EXEC master.dbo.xp_sqlagent_enum_jobs 1, 'sa', @job_id;
	-- SELECT * FROM @job_info;

	-- get schedule info for the job
	SELECT		s.schedule_id,
				'schedule_name' = name,
				enabled,
				freq_type,
				freq_interval,
				freq_subday_type,
				freq_subday_interval,
				freq_relative_interval,
				freq_recurrence_factor,
				active_start_date,
				active_end_date,
				active_start_time,
				active_end_time,
				date_created,
				'schedule_description' = FORMATMESSAGE(14549),
				js.next_run_date,
				js.next_run_time,
				s.schedule_uid
	INTO		#job_schedule_info
	FROM		msdb.dbo.sysjobschedules AS js
				JOIN msdb.dbo.sysschedules AS s
					ON js.schedule_id = s.schedule_id
	WHERE		JS.JOB_ID = @job_id;
--	SELECT * FROM #job_schedule_info;
	
	-- Check if job has exceeded expected runtime
	IF EXISTS (SELECT 1 FROM @job_info WHERE running = 1) BEGIN
		-- 'Still running';

		SELECT	@nextScheduleDate = next_run_date
			,	@nextScheduleTime = RIGHT('000000' + CAST(next_run_time AS VARCHAR), 6)
		FROM @job_info
		;
		
		SET @nextSchedule = SUBSTRING(@nextScheduleDate, 1, 4) + '-' + SUBSTRING(@nextScheduleDate, 5, 2) + '-' + SUBSTRING(@nextScheduleDate, 7, 2) + ' '
			+ SUBSTRING(@nextScheduleTime, 1, 2) + ':' + SUBSTRING(@nextScheduleTime, 3, 2) + ':' + SUBSTRING(@nextScheduleTime, 5, 2)
			;
		--	print cast (@nextSchedule as varchar);
		
		SET @maxSchedule = DATEADD(n, @maxRunTime, @nextSchedule);
		-- print cast (@maxSchedule as varchar);
		--PRINT CONVERT(VARCHAR(12), @maxSchedule, 101);
		
		SET @msg = 'Alert: ' + @@SERVERNAME + ' ' + @jobName + ' exceeded expected runtime of ' + CAST(@maxRunTime AS VARCHAR) + ' minutes';
		RAISERROR(@msg, 16, 1);
		RETURN(1);
	END
	ELSE
	BEGIN
		SET @msg = @jobName + ' is not running';
		PRINT @msg;
	END

	RETURN(0);

SET NOCOUNT OFF
SET ANSI_NULLS OFF
SET QUOTED_IDENTIFIER OFF

